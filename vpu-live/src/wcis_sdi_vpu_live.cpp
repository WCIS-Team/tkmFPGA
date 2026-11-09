// SDI capture from the vendor case; VPU JPEG/NV12 contract from repos/vpu-live.
// RGB565 -> NV12 follows its hdmi_display_actor.hpp. No HDMI or model session.
#include "pipeline/io/input/sdicamera.hpp"
#include "pipeline/vpu/vpu.h"
#include "wcis_capture_wait.hpp"
#include "wcis_sdi_diagnostics.hpp"
#include <poll.h>
#include <sys/file.h>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>
namespace fs=std::filesystem;
static volatile std::sig_atomic_t stop_requested=0;
static void signal_stop(int){stop_requested=1;}
static double now(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
static uint64_t now_ms(){return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
struct Profile{const char* codec;unsigned width,height,fps;int buffers;uint32_t pixfmt;};
static bool parse_size(const std::string& text,unsigned& w,unsigned& h){
 auto x=text.find('x');if(x==std::string::npos)return false;
 try{w=(unsigned)std::stoul(text.substr(0,x));h=(unsigned)std::stoul(text.substr(x+1));}
 catch(const std::exception&){return false;}
 return (w==960&&h==540)||(w==1280&&h==720)||(w==1920&&h==1080);
}
// 960x540 is the only H.264 geometry measured on this board (10-15 #199); 1080p is the goal, not yet evidence.
static Profile select_profile(const std::string& codec,const std::string& size){
 Profile p=codec=="jpeg"?Profile{"jpeg",960,540,5,2,V4L2_PIX_FMT_JPEG}
  :codec=="h264"?Profile{"h264",960,540,30,6,V4L2_PIX_FMT_H264}
  :throw std::runtime_error("codec must be jpeg or h264");
 if(!parse_size(size,p.width,p.height))throw std::runtime_error("size must be 960x540, 1280x720 or 1920x1080");
 p.fps=codec=="jpeg"?5u:30u;
 return p;
}
namespace annexb {
// nal_unit_type is the low five bits after the start code; this VPU emits no type 31.
static int start_code_len(const unsigned char* p,int size,int i){
 if(i+4<size&&p[i]==0&&p[i+1]==0&&p[i+2]==0&&p[i+3]==1)return 4;
 if(i+3<size&&p[i]==0&&p[i+1]==0&&p[i+2]==1)return 3;
 return 0;
}
static int nal_type(const unsigned char* p,int size,int i,int sc){return i+sc>=size?-1:p[i+sc]&0x1f;}
static int offset_of(const unsigned char* p,int size,int type){
 for(int i=0;i+3<size;){int sc=start_code_len(p,size,i);
  if(sc){if(nal_type(p,size,i,sc)==type)return i;i+=sc;continue;}
  ++i;}
 return -1;
}
// One output block is one picture (10-15 simulation: 150 frames gave 151 blocks).
static long pictures(const unsigned char* p,int size){
 long n=0;
 for(int i=0;i+3<size;){int sc=start_code_len(p,size,i);
  if(sc){int t=nal_type(p,size,i,sc);if(t==5||t==1)++n;i+=sc;continue;}
  ++i;}
 return n?n:1;
}
}
class LiveEncoder:public vpu::Encoder {
public:
 size_t inputBytes(){size_t n=0;for(auto x:input_buffers.at(0)->byte_per_planes_)n+=x;return n;}
 size_t uvOffset(){return input_format_.fmt.pix_mp.num_planes==2?input_buffers.at(0)->byte_per_planes_.at(0):size_t(profile_.width)*profile_.height;}
 bool pollOutput(std::vector<unsigned char>& bytes,int timeout){
  pollfd p{fd_,POLLIN,0};int n;
  do {n=::poll(&p,1,timeout);}while(n<0&&errno==EINTR&&!stop_requested);
  if(n==0)return false;
  if(n<0||!(p.revents&POLLIN))throw std::runtime_error("VPU output poll failed");
  v4l2_buffer b{};b.type=V4L2_BUF_TYPE_VIDEO_CAPTURE;b.memory=V4L2_MEMORY_MMAP;
  if(ioctl(fd_,VIDIOC_DQBUF,&b))throw std::runtime_error("VPU output dequeue failed");
  auto it=output_buffers.find(b.index);
  if(it==output_buffers.end())throw std::runtime_error("VPU output buffer index invalid");
  size_t offset=b.m.offset&4095,capacity=it->second->byte_per_planes_.at(0);
  if(offset>capacity||b.bytesused>capacity-offset||b.bytesused>5*1024*1024)throw std::runtime_error("VPU output bounds invalid");
  auto ptr=static_cast<unsigned char*>(it->second->ptr_[0])+offset;
  // Own the bytes before returning the mapped buffer to the driver.
  bytes.assign(ptr,ptr+b.bytesused);
  if(ioctl(fd_,VIDIOC_QBUF,&b))throw std::runtime_error("VPU output requeue failed");
  return true;
 }
protected:
 explicit LiveEncoder(const Profile& profile):vpu::Encoder("/dev/video0",profile.height,profile.width,
  V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,V4L2_PIX_FMT_NV12,V4L2_BUF_TYPE_VIDEO_CAPTURE,profile.pixfmt,profile.buffers),
  profile_(profile){
  // The vendor pump also swallows this; losing it only costs the timing metadata, not the stream.
  try{setFrameRate(profile.fps);}
  catch(const std::exception& e){std::cerr<<"FRAME_RATE_REJECTED "<<profile.fps<<" fps: "<<e.what()<<"\n";}
  auto& f=input_format_.fmt.pix_mp;
  if(f.width!=profile.width||f.height!=profile.height||(f.num_planes!=1&&f.num_planes!=2)||
     f.plane_fmt[0].bytesperline!=profile.width||(f.num_planes==2&&f.plane_fmt[1].bytesperline!=profile.width))
   throw std::runtime_error("VPU NV12 geometry/stride contract mismatch");
 }
 Profile profile_;
};
class JpegEncoder:public LiveEncoder {
public:
 explicit JpegEncoder(const Profile& profile):LiveEncoder(profile){
  v4l2_control c{};c.id=0x009d0903;c.value=80;
  if(ioctl(fd_,VIDIOC_S_CTRL,&c))throw std::runtime_error("VPU JPEG quality rejected");
 }
 bool take(std::vector<unsigned char>& bytes,int timeout){
  if(!pollOutput(bytes,timeout))return false;
  if(bytes.size()<4||bytes[0]!=255||bytes[1]!=216||bytes[bytes.size()-2]!=255||bytes.back()!=217)
   throw std::runtime_error("VPU did not produce one complete JPEG");
  return true;
 }
};
class H264Encoder:public LiveEncoder {
public:
 explicit H264Encoder(const Profile& profile):LiveEncoder(profile){}
 // Blocking drain through the vendor call. The demo pump (1080p, 102 segments) and live_sim (300
 // frames) both used it; this binary's own poll-then-DQBUF version took an encoder MMU ABORT at
 // frame 8, so the H.264 side does not get to keep the unproven variant.
 bool nextOutput(std::vector<unsigned char>& bytes){
  void* ptr=nullptr;int size=0;
  bool more=getOutput(ptr,size);
  bytes.clear();
  if(size>0&&ptr){
   if(size>5*1024*1024)throw std::runtime_error("VPU output bounds invalid");
   // getOutput requeues the driver buffer before returning, so copy before anything else.
   bytes.assign(static_cast<unsigned char*>(ptr),static_cast<unsigned char*>(ptr)+size);
  }
  return more;
 }
};
// Annex-B ring the board-side HLS packager reads: seg<N>.h264 + seg<N>.info + state.
class H264Segments {
public:
 H264Segments(fs::path dir,unsigned fps):dir_(std::move(dir)),seg_frames_(fps?fps:1){}
 std::atomic<long> segments{0},pictures{0},bytes_out{0},chunks{0},head_bytes{0};
 bool dead()const{return dead_;}
 std::string error()const{std::lock_guard<std::mutex> g(mu_);return error_;}
 void write(const unsigned char* b,size_t length){
  if(dead_||length==0||length>4u*1024*1024)return;
  int size=int(length);
  int io=annexb::offset_of(b,size,5);
  ++chunks;
  if(!head_ready_){
   if(io<0){
    // The session's first block is a standalone SPS+PPS buffer (32/33 B at 30 fps) and holds no IDR.
    if(head_.size()+length>head_max_){fail("no IDR within "+std::to_string(head_max_)+" B of head");return;}
    head_.insert(head_.end(),b,b+size);
    head_bytes.store((long)head_.size());
    return;
   }
   head_ready_=true;
   head_.insert(head_.end(),b,b+io);
   head_bytes.store((long)head_.size());
   if(!openSeg())return;
   append(b+io,size-io,1);
   seg_started_ms_=now_ms();
   return;
  }
  if(io>=0&&(in_seg_>=long(seg_frames_)||now_ms()-seg_started_ms_>=uint64_t(seg_ms_max_))){
   // A block that carries its own parameter set ahead of the IDR supersedes the cached one.
   // io==0 must leave the cache alone: overwriting it with the empty prefix is what broke #195.
   // Only supersede the cached parameter set when this prefix carries an SPS;
   // a prefix with no param set (e.g. a leading SEI) must not overwrite the good cache.
   if(io>0&&prefixHasSps(b,io)){head_.assign(b,b+io);head_bytes.store((long)head_.size());}
   seal();
   if(!openSeg())return;
   append(b+io,size-io,1);
   seg_started_ms_=now_ms();
   return;
  }
  append(b,size,annexb::pictures(b,size));
 }
 // Seal whatever is open; the packager must never see a half-written or segment-less tail.
 void finish(){
  if(!dead_)seal();
  writeState();
 }
 void fail(const std::string& reason){
  {std::lock_guard<std::mutex> g(mu_);if(!dead_){dead_=true;error_=reason;}}
  if(cur_.is_open()){cur_.flush();cur_.close();}
  writeState();
 }
private:
 fs::path dir_;
 unsigned seg_frames_;
 int seg_ms_max_=2000;
 int keep_=7;
 static constexpr size_t head_max_=4096;
 // True when the Annex-B prefix [b,b+n) begins with an SPS (NAL type 7).
 static bool prefixHasSps(const unsigned char* b,long n){
  for(long i=0;i+4<=n;){
   if(b[i]==0&&b[i+1]==0&&(b[i+2]==1||(b[i+2]==0&&b[i+3]==1))){
    long off=(b[i+2]==1)?i+3:i+4;
    if(off<n)return (b[off]&0x1f)==7;
    return false;
   }
   ++i;
  }
 }
 std::vector<unsigned char> head_;
 bool head_ready_=false;
 std::atomic<bool> dead_{false};
 std::string error_;
 mutable std::mutex mu_;
 std::ofstream cur_;
 fs::path part_,final_;
 long seq_=-1,in_seg_=0;
 uint64_t seg_started_ms_=0;
 bool openSeg(){
  ++seq_;
  std::string stem="seg"+std::to_string(seq_);
  part_=dir_/(stem+".part");
  final_=dir_/(stem+".h264");
  cur_.open(part_,std::ios::binary|std::ios::trunc);
  if(!cur_.is_open()){fail("cannot open "+part_.string());return false;}
  in_seg_=0;
  // The parameter set arrives once per session, so every segment head is written from the cache.
  if(!head_.empty()&&!cur_.write(reinterpret_cast<const char*>(head_.data()),(std::streamsize)head_.size())){
   fail("segment head write failed");cur_.close();return false;}
  return true;
 }
 void append(const unsigned char* b,int size,long count){
  if(size<=0)return;
  if(!cur_.write(reinterpret_cast<const char*>(b),size)){fail("segment write failed (tmpfs full?)");cur_.close();return;}
  cur_.flush();
  bytes_out.fetch_add(size);
  pictures.fetch_add(count);
  in_seg_+=count;
  if(pictures.load()%30==0)writeState();
 }
 void seal(){
  if(!cur_.is_open())return;
  cur_.flush();cur_.close();
  // Write the sidecar .info *before* the .h264 becomes visible, so the packager
  // can never observe a segment whose frame count it has to guess.
  std::ofstream info(dir_/("seg"+std::to_string(seq_)+".info"),std::ios::binary|std::ios::trunc);
  info<<"frames="<<in_seg_<<"\n";
  info.close();
  std::error_code ec;
  fs::rename(part_,final_,ec);
  if(ec){fail("segment rename failed: "+ec.message());return;}
  segments.store(seq_+1);
  prune();
  writeState();
 }
 void prune(){
  for(long n=0;n+keep_<=seq_;++n){
   std::string stem="seg"+std::to_string(n);std::error_code ec;
   fs::remove(dir_/(stem+".h264"),ec);
   fs::remove(dir_/(stem+".info"),ec);
  }
 }
 void writeState(){
  char buf[512];
  int len=snprintf(buf,sizeof(buf),
   "seq=%ld bytes_total=%ld frames=%ld frames_in_seg=%ld chunks=%ld head_bytes=%ld "
   "fps=%u seg_frames=%u keep=%d dir=%s dead=%d pid=%d unix=%ld error=%s\n",
   (long)segments.load(),(long)bytes_out.load(),(long)pictures.load(),in_seg_,(long)chunks.load(),
   (long)head_bytes.load(),seg_frames_,seg_frames_,keep_,dir_.string().c_str(),dead()?1:0,(int)getpid(),
   (long)time(nullptr),dead()?error().c_str():"-");
  std::ofstream s(dir_/"state",std::ios::binary|std::ios::trunc);
  if(len<0)len=0;
  if(len>=(int)sizeof(buf))len=sizeof(buf)-1;
  s.write(buf,len);
 }
};
int main(int argc,char** argv){
 if(argc<6||argc>7){std::cerr<<"Usage: wcis_sdi_vpu_live camera|vtc EXPECTED_BOOT OUTDIR FRAME_LIMIT(0=continuous) jpeg|h264 [960x540|1280x720|1920x1080]\n";return 2;}
 std::string source=argv[1],codec=argv[5],boot;std::ifstream("/proc/sys/kernel/random/boot_id")>>boot;
 if((source!="camera"&&source!="vtc")||boot.empty()||boot!=argv[2])return 2;
 Profile profile;
 try{profile=select_profile(codec,argc==7?argv[6]:"960x540");}
 catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 2;}
 for(const char* name:{"WCIS_NPU_LOCK_FD","WCIS_CAMERA_LOCK_FD"}){
  auto value=getenv(name);if(!value)return 2;int fd=atoi(value);
  if(fd<3||fcntl(fd,F_GETFD)<0||flock(fd,LOCK_EX|LOCK_NB))return 2;
 }
 const int limit=std::stoi(argv[4]);if(limit<0||limit>3600)return 2;
 // vpu.h only turns the stream on after `buffers` enqueues, so a shorter run can never encode a frame.
 if(limit&&limit<profile.buffers+1){std::cerr<<(codec=="h264"?"h264 needs at least 7 frames":"jpeg needs at least 3 frames")<<"\n";return 2;}
 fs::path out=argv[3];if(out.string().find("/dev/shm/wcis-")!=0)return 2;
 fs::create_directories(out);
 std::signal(SIGINT,signal_stop);std::signal(SIGTERM,signal_stop);
 unsigned captured=0,encoded=0;bool pending=false,configured=false;
 std::unique_ptr<JpegEncoder> jpeg;std::unique_ptr<H264Encoder> h264;
 std::unique_ptr<H264Segments> segments;std::thread drainer;std::atomic<bool> drain_stop{false};
 struct Frame{unsigned id;double captured_at;};std::deque<Frame> queue;
 auto metadata=[&](const char* state,unsigned id,double timestamp){
  unsigned long enc=segments?static_cast<unsigned long>(segments->pictures.load()):encoded;
  unsigned long segs=segments?static_cast<unsigned long>(segments->segments.load()):0;
  return std::string("{\"source\":\"")+source+"\",\"codec\":\""+codec+"\",\"state\":\""+state+"\",\"boot_id\":\""+boot+
   "\",\"pid\":"+std::to_string(getpid())+",\"frame_id\":"+std::to_string(id)+",\"captured\":"+std::to_string(captured)+
   ",\"encoded\":"+std::to_string(enc)+",\"segments\":"+std::to_string(segs)+
   ",\"width\":"+std::to_string(profile.width)+",\"height\":"+std::to_string(profile.height)+
   ",\"fps_limit\":"+std::to_string(profile.fps)+",\"captured_at\":"+std::to_string(timestamp)+
   ",\"updated_at\":"+std::to_string(now())+"}";
 };
 auto status=[&](const char* state){std::ofstream f(out/"status.tmp");f<<metadata(state,encoded,0);f.close();fs::rename(out/"status.tmp",out/"status.json");};
 status("starting");
 try{
  auto device=icraft::xrt::Device::Open("axi://zg330aiu?npu=0x40000000&dma=0x80000000");
  auto fpai=device.cast<fpai::FPAIDevice>();auto regs=fpai.defaultRegRegion();constexpr uint64_t base=0x40080000;
  auto read=[&](uint32_t offset){return static_cast<uint32_t>(regs.read(base+offset));};
  if(read(0x0c)!=0x20230218||read(4)||read(8)||read(0x44)||read(0x70))throw std::runtime_error("camera version/busy state mismatch");
  const size_t frame_bytes=size_t(profile.width)*profile.height*2;
  auto chunk=fpai.getMemRegion("udma").malloc(frame_bytes,false);
  auto address=chunk->begin.addr();if(address%8||address<0x30100000||address+frame_bytes>0x38100000)throw std::runtime_error("unverified UDMA allocation");
  fpai::GenericSDICamera camera(0,fpai,1920,1080,camera_fmt::RGB565,profile.width,profile.height,camera_fmt::RGB565,crop_position::center,640,352,crop_position::center,base,source=="vtc");
  configured=true;regs.write(base+0x44,0);regs.write(base+8,0);
  if((read(0xb4)&1)!=(source=="vtc"))throw std::runtime_error("source selection readback mismatch");
  std::vector<unsigned char> raw(frame_bytes),nv12;cv::Mat bgr,i420;
  auto publish=[&](int wait){
   std::vector<unsigned char> jpeg_bytes;if(!jpeg->take(jpeg_bytes,wait))return false;
   if(queue.empty())throw std::runtime_error("VPU output has no source frame identity");
   auto frame=queue.front();queue.pop_front();++encoded;
   if(encoded==1){auto decoded=cv::imdecode(jpeg_bytes,cv::IMREAD_COLOR);
    if(decoded.cols!=int(profile.width)||decoded.rows!=int(profile.height))throw std::runtime_error("VPU JPEG decode check failed");}
   auto info=metadata("ready",frame.id,frame.captured_at);uint32_t len=info.size();
   std::ofstream f(out/"latest.tmp",std::ios::binary);f.write(reinterpret_cast<char*>(&len),4);f.write(info.data(),info.size());
   f.write(reinterpret_cast<char*>(jpeg_bytes.data()),jpeg_bytes.size());f.close();
   if(!f)throw std::runtime_error("frame packet write failed");fs::rename(out/"latest.tmp",out/"latest.frame");status("ready");return true;
  };
  while(!stop_requested&&(!limit||captured<static_cast<unsigned>(limit))){
   if(source=="camera"){
    auto diag=wcis::read_sdi_diagnostics([&](uint64_t address){return static_cast<uint32_t>(regs.read(address));},base);
    if(diag.state!=wcis::SdiReadState::Ready)throw std::runtime_error("SDI2 input monitor unavailable; capture not requested");
    if((diag.words[2]&3)!=3||!(diag.words[6]&1)){
     status("waiting_for_sdi_lock");std::this_thread::sleep_for(std::chrono::milliseconds(200));continue;
    }
    if(diag.words[11]!=((1080u<<16)|1920u)){
     status("input_format_mismatch");std::this_thread::sleep_for(std::chrono::milliseconds(200));continue;
    }
   }
   if(stop_requested)break;
   double start=now();pending=true;
   wcis::CaptureResult result;
   try {
    camera.take(chunk);
    result=wcis::wait_capture([&]{return read(0x58);},[]{return stop_requested!=0;},2000,true);
   }catch(...){status("capture_failed_requires_reboot");std::_Exit(3);}
   if(result.state!=wcis::CaptureState::Done){status("capture_failed_requires_reboot");std::cerr<<"CAPTURE_FAILED status="<<result.status<<" captured="<<captured<<"; no retry\n"<<std::flush;std::_Exit(3);}
   pending=false;++captured;Frame frame{captured,now()};chunk.read(reinterpret_cast<char*>(raw.data()),0,raw.size());
   cv::Mat input(profile.height,profile.width,CV_8UC2,raw.data());cv::cvtColor(input,bgr,cv::COLOR_BGR5652BGR);cv::cvtColor(bgr,i420,cv::COLOR_BGR2YUV_I420);
   if(!jpeg&&!h264){
    if(profile.pixfmt==V4L2_PIX_FMT_JPEG)jpeg=std::make_unique<JpegEncoder>(profile);
    else{
     h264=std::make_unique<H264Encoder>(profile);
     segments=std::make_unique<H264Segments>(out,profile.fps);
     drainer=std::thread([&]{
      std::vector<unsigned char> block;
      try{
       uint64_t waited=now_ms();
       while(!h264->streamon_flag_.load()&&!stop_requested&&!drain_stop&&now_ms()-waited<20000)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
       if(drain_stop||stop_requested)return;
       if(!h264->streamon_flag_.load()){segments->fail("capture queue never started");return;}
       while(!stop_requested&&!drain_stop){
        bool more=h264->nextOutput(block);
        if(!block.empty())segments->write(block.data(),block.size());
        if(segments->dead()){stop_requested=1;return;}
        if(!more){segments->fail("encoder reported end of stream");stop_requested=1;return;}
       }
      }catch(const std::exception& e){if(!drain_stop){segments->fail(e.what());stop_requested=1;}}
      catch(...){if(!drain_stop){segments->fail("output drain failed");stop_requested=1;}}
     });
    }
   }
   LiveEncoder& encoder=jpeg?static_cast<LiveEncoder&>(*jpeg):static_cast<LiveEncoder&>(*h264);
   size_t size=encoder.inputBytes();
   if(size<size_t(profile.width)*profile.height*3/2||size>16*1024*1024)throw std::runtime_error("VPU input buffer size mismatch");
   if(nv12.size()!=size)nv12.resize(size);
   const size_t y=size_t(profile.width)*profile.height;size_t uv=encoder.uvOffset();
   if(uv<y||uv+y/2>nv12.size())throw std::runtime_error("VPU NV12 plane bounds mismatch");
   std::memcpy(nv12.data(),i420.data,y);
   for(size_t i=0;i<y/4;++i){nv12[uv+2*i]=i420.data[y+i];nv12[uv+2*i+1]=i420.data[y+y/4+i];}
   if(jpeg){
    if(queue.size()>=6)throw std::runtime_error("VPU output stalled");
    queue.push_back(frame);encoder.enqueueDataPtr(reinterpret_cast<char*>(nv12.data()));
    if(captured>=3)publish(1500);
    while(encoder.streamon_flag_.load()&&publish(0)){}
   } else {
    encoder.enqueueDataPtr(reinterpret_cast<char*>(nv12.data()));
    if(captured==1||captured%5==0)status("ready");
    if(captured==profile.fps||captured%(10*profile.fps)==0)
     std::cout<<"H264 captured="<<captured<<" pictures="<<segments->pictures.load()
      <<" segments="<<segments->segments.load()<<" bytes="<<segments->bytes_out.load()<<"\n"<<std::flush;
   }
   double pacing=1.0/double(profile.fps?profile.fps:1);
   while(!stop_requested&&now()-start<pacing)std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  if(jpeg){while(!queue.empty()&&publish(1500)){}jpeg->streamOff();jpeg.reset();}
  if(h264){
   // Frames still inside the encoder at loop exit are worth waiting for; the drain thread owns the queue.
   uint64_t until=now_ms()+1000;
   while(segments->pictures.load()<long(captured)&&!segments->dead()&&now_ms()<until)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
   drain_stop=true;
   // getOutput blocks in DQBUF, so streamOff is the only thing that can release the drainer.
   try{h264->streamOff();}catch(...){}
   if(drainer.joinable())drainer.join();
   segments->finish();
   if(segments->dead())throw std::runtime_error("H.264 pump died: "+segments->error());
   h264.reset();
  }
  regs.write(base+0xb4,0);regs.write(base+0x18,0);status("stopped");
  long pictures=segments?segments->pictures.load():long(encoded);
  long head=segments?segments->head_bytes.load():0;
  std::cout<<"RESULT source="<<source<<" codec="<<codec<<" size="<<profile.width<<"x"<<profile.height
   <<" captured="<<captured<<" pictures="<<pictures<<" segments="<<(segments?segments->segments.load():0)
   <<" bytes="<<(segments?segments->bytes_out.load():0)<<" head_bytes="<<head<<"\n"<<std::flush;
  return (pictures>0||stop_requested)&&(segments?true:queue.empty())?0:4;
 }catch(const std::exception& e){
  status(pending?"capture_failed_requires_reboot":(configured?"hardware_error_requires_review":"startup_failed"));std::cerr<<e.what()<<"\n"<<std::flush;
  if(jpeg){try{jpeg->streamOff();}catch(...){}jpeg.reset();}
  if(h264){drain_stop=true;try{h264->streamOff();}catch(...){}if(drainer.joinable()){try{drainer.join();}catch(...){}}segments->finish();h264.reset();}
  // If capture may still be active, avoid freeing a DMA buffer in stack unwinding.
  std::_Exit(2);
 }
}
