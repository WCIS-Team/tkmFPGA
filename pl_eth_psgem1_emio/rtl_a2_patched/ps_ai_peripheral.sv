//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : ps_ai_peripheral.sv
// Author        : 
// Project       : 
// Create Date   : 2026.03.20
// Description   :
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
//==============================================================================

module ps_ai_peripheral (
  // PS DDR
  inout     [53 : 0]     FIXED_IO_0_mio             ,
  inout     [14 : 0]     DDR_0_addr                 , 
  inout     [2  : 0]     DDR_0_ba                   , 
  inout                  DDR_0_cas_n                , 
  inout                  DDR_0_ck_n                 , 
  inout                  DDR_0_ck_p                 , 
  inout                  DDR_0_cke                  , 
  inout                  DDR_0_cs_n                 , 
  inout     [3  : 0]     DDR_0_dm                   , 
  inout     [31 : 0]     DDR_0_dq                   , 
  inout     [3  : 0]     DDR_0_dqs_n                , 
  inout     [3  : 0]     DDR_0_dqs_p                , 
  inout                  DDR_0_odt                  , 
  inout                  DDR_0_ras_n                , 
  inout                  DDR_0_reset_n              , 
  inout                  DDR_0_we_n                 , 
  inout                  FIXED_IO_0_ddr_vrn         , 
  inout                  FIXED_IO_0_ddr_vrp         , 
  inout                  FIXED_IO_0_ps_clk          ,
  inout                  FIXED_IO_0_ps_porb         ,
  inout                  FIXED_IO_0_ps_srstb        ,

  // PL DDR  
  inout     [ 63 : 0]    ddr3_dq                    ,
  inout     [  7 : 0]    ddr3_dqs_n                 ,
  inout     [  7 : 0]    ddr3_dqs_p                 ,
  output    [  7 : 0]    ddr3_dm                    ,
  output    [ 14 : 0]    ddr3_addr                  ,
  output    [  2 : 0]    ddr3_ba                    ,
  output                 ddr3_ras_n                 ,
  output                 ddr3_cas_n                 ,
  output                 ddr3_we_n                  ,
  output                 ddr3_reset_n               ,
  output    [  0 : 0]    ddr3_ck_p                  ,
  output    [  0 : 0]    ddr3_ck_n                  ,
  output    [  0 : 0]    ddr3_cke                   ,
  output    [  0 : 0]    ddr3_cs_n                  ,
  output    [  0 : 0]    ddr3_odt                   ,
       
  input                  sys_rst                    ,
  input                  sys_clk_p                  ,
  input                  sys_clk_n                  ,

  // CAM
  input                  cam_vs                    ,
  input     [ 23  :0]    cam_rgb                   ,
  input                  cam_clk                   ,
  input                  cam_data_en               ,

  // SDI status + measured active geometry (hp_clk domain, see rx_sdi.v)
  input    [ 159  :0]    sdi_status_bus           ,

  output                 HDMI_CLK_P                 ,    
  output                 HDMI_CLK_N                 , 
  output [2:0]           HDMI_TX_P                  , 
  output [2:0]           HDMI_TX_N                  ,      
 
  output    [  1 : 0]    led                       ,
  input                  led3                      ,

  input                  PJTAG_TCK                 ,
  input                  PJTAG_TMS                 ,
  input                  PJTAG_TDI                 ,
  output                 PJTAG_TDO                 ,

  output                 gp_clk                    ,
  output                 hp_clk                    ,
  output                 gp_clk_rst                ,
  output                 hp_clk_rst                ,

  //User CustomOp REG BUS -> master ports
  output    [ 31 : 0]    User_Reg_awwaddr          ,
  output    [ 31 : 0]    User_Reg_awwdata          ,
  output                 User_Reg_awwvalid         ,
  input                  User_Reg_awwready         ,

  output    [ 31 : 0]    User_Reg_araddr           ,
  output                 User_Reg_arvalid          ,
  input                  User_Reg_arready          ,
  input     [ 31 : 0]    User_Reg_rdata            ,
  input                  User_Reg_rvalid           ,
  output                 User_Reg_rready           ,

  //User CustomOp DATA BUS -> slave ports
  input     [ 31 : 0]    User_Ddr_awwaddr          ,
  input     [511 : 0]    User_Ddr_awwdata          ,
  input     [ 71 : 0]    User_Ddr_awwinfo          , //{1'b0,pl_awen[63:0],pl_awinfo[5:0],pl_awlast[0]}
  input                  User_Ddr_awwvalid         ,
  output                 User_Ddr_awwready         ,

  input     [ 31 : 0]    User_Ddr_araddr           ,
  input                  User_Ddr_arvalid          ,
  input     [ 31:  0]    User_Ddr_arinfo           ,  //{25'h0,pl_arinfo,pl_arlast}
  output                 User_Ddr_arready          ,
  output    [511 : 0]    User_Ddr_rdata            ,
  output                 User_Ddr_rvalid           ,
  output    [ 31:  0]    User_Ddr_rinfo            ,  //{25'h0,pl_rinfo,pl_rlast}
  input                  User_Ddr_rready       ,
  // WCIS-PL-ETH A2 begin
  output                 RGMII_0_txc           ,
  output                 RGMII_0_tx_ctl        ,
  output      [  3 : 0]  RGMII_0_td            ,
  input                  RGMII_0_rxc           ,
  input                  RGMII_0_rx_ctl        ,
  input       [  3 : 0]  RGMII_0_rd            ,
  output                 MDIO_PHY_0_mdc        ,
  inout                  MDIO_PHY_0_mdio_io    ,
  output      [  0 : 0]  phy_reset_n            
  // WCIS-PL-ETH A2 end
);


    // ************************************************************************************
    //   BUYI AI
    // ************************************************************************************
    wire          [      26 : 0]   pl_awaddr        ;
    wire          [     511 : 0]   pl_awdata        ;
    wire          [      63 : 0]   pl_awen          ;
    wire          [       5 : 0]   pl_awinfo        ; // {awdbg_4, awsts_1, awstv_1}
    wire                           pl_awlast        ;
    wire                           pl_awvalid       ;
    wire                           pl_awready       ;
    wire          [      26 : 0]   pl_araddr        ;
    wire          [       5 : 0]   pl_arinfo        ; // {ardbg_4, arstc_1, arstv_1}
    wire                           pl_arlast        ;
    wire                           pl_arvalid       ;
    wire                           pl_arready       ;
    wire          [     511 : 0]   pl_rdata         ;
    wire                           pl_rvalid        ;
    wire                           pl_rlast         ;
    wire                           pl_rready        ;
    wire          [      15 : 0]   pl_ra_awaddr     ;  //{broadcast_1, col_id_4, row_id_4, offset_7}  
    wire          [      31 : 0]   pl_ra_awdata     ;
    wire                           pl_ra_awvalid    ;
    wire                           pl_ra_awready    ;
    wire          [      15 : 0]   pl_ra_araddr     ;  //{NA_1, col_id_4, row_id_4, offset_7}  
    wire                           pl_ra_arvalid    ;
    wire                           pl_ra_arready    ;
    wire          [      31 : 0]   pl_ra_rdata      ;
    wire                           pl_ra_rvalid     ;
    wire                           pl_ra_rready     ;
    wire          [      17 : 0]   pl_int_info      ;
    wire                           pl_int_valid     ;
    wire                           pl_int_ready     ;
    wire                           pl_ra_clk        ;
    wire                           pl_itf_clk       ;
    wire                           pl_rst_n         ;
    wire                           pl_clk_en_b      ;
    wire                           pl_bist_clk      ;
    wire                           pl_bist_rstn     ;
    wire                           pl_bist_en       ;
    wire                           pl_bist_err      ;
    wire                           pl_bist_done     ;
    wire                           pl_repair_done   ;  
    wire                           pl_repair_fail   ; 
    wire                           pl_clk_div_out   ;   // for clk check, you can set false path for this signal
    wire                           pl_scan_mode_b   ;
    wire                           pl_scan_en       ;
    wire                           pl_scan_clk      ;
    wire                           pl_scan_rst_n    ;
    wire                           pl_scan_pipe_clk ;
    wire          [    83 : 0  ]   pl_scan_i        ;    
    wire          [    63 : 0  ]   pl_scan_o        ;

    wire                           reset_100mhz     ;    

    wire          [    31 : 0  ]    gp0_ar_cnt      ;        
    wire          [    31 : 0  ]    gp0_r_cnt       ;        
    wire          [    31 : 0  ]    gp0_aw_cnt      ;           
    wire          [    31 : 0  ]    gp0_w_cnt       ;        
    wire          [    31 : 0  ]    gp0_b_cnt       ;        
   
    wire          [    31 : 0  ]    gp1_ar_cnt      ;        
    wire          [    31 : 0  ]    gp1_r_cnt       ;        
    wire          [    31 : 0  ]    gp1_aw_cnt      ;        
    wire          [    31 : 0  ]    gp1_w_cnt       ;          
    wire          [    31 : 0  ]    gp1_b_cnt       ; 

    wire          [     3 : 0  ]    hp_disable      ; 

  // ************************************************************************************
  //   PS-PL
  // ************************************************************************************
    wire              BYolo_GP0_ARVALID;
    wire              BYolo_GP0_AWVALID;
    wire              BYolo_GP0_BREADY ;
    wire              BYolo_GP0_RREADY ;
    wire              BYolo_GP0_WLAST  ;
    wire              BYolo_GP0_WVALID ;
    wire     [11 : 0] BYolo_GP0_ARID   ;
    wire     [11 : 0] BYolo_GP0_AWID   ;
    wire     [11 : 0] BYolo_GP0_WID    ;
    wire     [1 : 0]  BYolo_GP0_ARBURST;
    wire     [1 : 0]  BYolo_GP0_ARLOCK ;
    wire     [2 : 0]  BYolo_GP0_ARSIZE ;
    wire     [1 : 0]  BYolo_GP0_AWBURST;
    wire     [1 : 0]  BYolo_GP0_AWLOCK ;
    wire     [2 : 0]  BYolo_GP0_AWSIZE ;
    wire     [2 : 0]  BYolo_GP0_ARPROT ;
    wire     [2 : 0]  BYolo_GP0_AWPROT ;
    wire     [31 : 0] BYolo_GP0_ARADDR ;
    wire     [31 : 0] BYolo_GP0_AWADDR ;
    wire     [31 : 0] BYolo_GP0_WDATA  ;
    wire     [3 : 0]  BYolo_GP0_ARCACHE;
    wire     [3 : 0]  BYolo_GP0_ARLEN  ;
    wire     [3 : 0]  BYolo_GP0_ARQOS  ;
    wire     [3 : 0]  BYolo_GP0_AWCACHE;
    wire     [3 : 0]  BYolo_GP0_AWLEN  ;
    wire     [3 : 0]  BYolo_GP0_AWQOS  ;
    wire     [3 : 0]  BYolo_GP0_WSTRB  ;
    wire              BYolo_GP0_ARREADY;
    wire              BYolo_GP0_AWREADY;
    wire              BYolo_GP0_BVALID ;
    wire              BYolo_GP0_RLAST  ;
    wire              BYolo_GP0_RVALID ;
    wire              BYolo_GP0_WREADY ;
    wire     [11 : 0] BYolo_GP0_BID    ;
    wire     [11 : 0] BYolo_GP0_RID    ;
    wire     [1 : 0]  BYolo_GP0_BRESP  ;
    wire     [1 : 0]  BYolo_GP0_RRESP  ;
    wire     [31 : 0] BYolo_GP0_RDATA  ;
    
    wire              BYolo_GP1_ARVALID;
    wire              BYolo_GP1_AWVALID;
    wire              BYolo_GP1_BREADY ;
    wire              BYolo_GP1_RREADY ;
    wire              BYolo_GP1_WLAST  ;
    wire              BYolo_GP1_WVALID ;
    wire     [11 : 0] BYolo_GP1_ARID   ;
    wire     [11 : 0] BYolo_GP1_AWID   ;
    wire     [11 : 0] BYolo_GP1_WID    ;
    wire     [1 : 0]  BYolo_GP1_ARBURST;
    wire     [1 : 0]  BYolo_GP1_ARLOCK ;
    wire     [2 : 0]  BYolo_GP1_ARSIZE ;
    wire     [1 : 0]  BYolo_GP1_AWBURST;
    wire     [1 : 0]  BYolo_GP1_AWLOCK ;
    wire     [2 : 0]  BYolo_GP1_AWSIZE ;
    wire     [2 : 0]  BYolo_GP1_ARPROT ;
    wire     [2 : 0]  BYolo_GP1_AWPROT ;
    wire     [31 : 0] BYolo_GP1_ARADDR ;
    wire     [31 : 0] BYolo_GP1_AWADDR ;
    wire     [31 : 0] BYolo_GP1_WDATA  ;
    wire     [3 : 0]  BYolo_GP1_ARCACHE;
    wire     [3 : 0]  BYolo_GP1_ARLEN  ;
    wire     [3 : 0]  BYolo_GP1_ARQOS  ;
    wire     [3 : 0]  BYolo_GP1_AWCACHE;
    wire     [3 : 0]  BYolo_GP1_AWLEN  ;
    wire     [3 : 0]  BYolo_GP1_AWQOS  ;
    wire     [3 : 0]  BYolo_GP1_WSTRB  ;
    wire              BYolo_GP1_ARREADY;
    wire              BYolo_GP1_AWREADY;
    wire              BYolo_GP1_BVALID ;
    wire              BYolo_GP1_RLAST  ;
    wire              BYolo_GP1_RVALID ;
    wire              BYolo_GP1_WREADY ;
    wire     [11 : 0] BYolo_GP1_BID    ;
    wire     [11 : 0] BYolo_GP1_RID    ;
    wire     [1 : 0]  BYolo_GP1_BRESP  ;
    wire     [1 : 0]  BYolo_GP1_RRESP  ;
    wire     [31 : 0] BYolo_GP1_RDATA  ;

    wire              User_GP0_ARVALID;
    wire              User_GP0_AWVALID;
    wire              User_GP0_BREADY ;
    wire              User_GP0_RREADY ;
    wire              User_GP0_WLAST  ;
    wire              User_GP0_WVALID ;
    wire     [11 : 0] User_GP0_ARID   ;
    wire     [11 : 0] User_GP0_AWID   ;
    wire     [11 : 0] User_GP0_WID    ;
    wire     [1 : 0]  User_GP0_ARBURST;
    wire     [1 : 0]  User_GP0_ARLOCK ;
    wire     [2 : 0]  User_GP0_ARSIZE ;
    wire     [1 : 0]  User_GP0_AWBURST;
    wire     [1 : 0]  User_GP0_AWLOCK ;
    wire     [2 : 0]  User_GP0_AWSIZE ;
    wire     [2 : 0]  User_GP0_ARPROT ;
    wire     [2 : 0]  User_GP0_AWPROT ;
    wire     [31 : 0] User_GP0_ARADDR ;
    wire     [31 : 0] User_GP0_AWADDR ;
    wire     [31 : 0] User_GP0_WDATA  ;
    wire     [3 : 0]  User_GP0_ARCACHE;
    wire     [3 : 0]  User_GP0_ARLEN  ;
    wire     [3 : 0]  User_GP0_ARQOS  ;
    wire     [3 : 0]  User_GP0_AWCACHE;
    wire     [3 : 0]  User_GP0_AWLEN  ;
    wire     [3 : 0]  User_GP0_AWQOS  ;
    wire     [3 : 0]  User_GP0_WSTRB  ;
    wire              User_GP0_ACLK   ;
    wire              User_GP0_ARREADY;
    wire              User_GP0_AWREADY;
    wire              User_GP0_BVALID ;
    wire              User_GP0_RLAST  ;
    wire              User_GP0_RVALID ;
    wire              User_GP0_WREADY ;
    wire     [11 : 0] User_GP0_BID    ;
    wire     [11 : 0] User_GP0_RID    ;
    wire     [1 : 0]  User_GP0_BRESP  ;
    wire     [1 : 0]  User_GP0_RRESP  ;
    wire     [31 : 0] User_GP0_RDATA  ;
    
    wire              User_GP1_ARVALID;
    wire              User_GP1_AWVALID;
    wire              User_GP1_BREADY ;
    wire              User_GP1_RREADY ;
    wire              User_GP1_WLAST  ;
    wire              User_GP1_WVALID ;
    wire     [11 : 0] User_GP1_ARID   ;
    wire     [11 : 0] User_GP1_AWID   ;
    wire     [11 : 0] User_GP1_WID    ;
    wire     [1 : 0]  User_GP1_ARBURST;
    wire     [1 : 0]  User_GP1_ARLOCK ;
    wire     [2 : 0]  User_GP1_ARSIZE ;
    wire     [1 : 0]  User_GP1_AWBURST;
    wire     [1 : 0]  User_GP1_AWLOCK ;
    wire     [2 : 0]  User_GP1_AWSIZE ;
    wire     [2 : 0]  User_GP1_ARPROT ;
    wire     [2 : 0]  User_GP1_AWPROT ;
    wire     [31 : 0] User_GP1_ARADDR ;
    wire     [31 : 0] User_GP1_AWADDR ;
    wire     [31 : 0] User_GP1_WDATA  ;
    wire     [3 : 0]  User_GP1_ARCACHE;
    wire     [3 : 0]  User_GP1_ARLEN  ;
    wire     [3 : 0]  User_GP1_ARQOS  ;
    wire     [3 : 0]  User_GP1_AWCACHE;
    wire     [3 : 0]  User_GP1_AWLEN  ;
    wire     [3 : 0]  User_GP1_AWQOS  ;
    wire     [3 : 0]  User_GP1_WSTRB  ;
    wire              User_GP1_ACLK   ;
    wire              User_GP1_ARREADY;
    wire              User_GP1_AWREADY;
    wire              User_GP1_BVALID ;
    wire              User_GP1_RLAST  ;
    wire              User_GP1_RVALID ;
    wire              User_GP1_WREADY ;
    wire     [11 : 0] User_GP1_BID    ;
    wire     [11 : 0] User_GP1_RID    ;
    wire     [1 : 0]  User_GP1_BRESP  ;
    wire     [1 : 0]  User_GP1_RRESP  ;
    wire     [31 : 0] User_GP1_RDATA  ;

    wire     [7 : 0]  S_AXI_HP1_RCOUNT        ;
    wire     [7 : 0]  S_AXI_HP1_WCOUNT        ;
    wire     [2 : 0]  S_AXI_HP1_RACOUNT       ;
    wire     [5 : 0]  S_AXI_HP1_WACOUNT       ;

    wire              S_AXI_HP0_RDISSUECAP1_EN;
    wire              S_AXI_HP0_WRISSUECAP1_EN;
    wire              S_AXI_HP1_RDISSUECAP1_EN;
    wire              S_AXI_HP1_WRISSUECAP1_EN;
    wire              S_AXI_HP2_RDISSUECAP1_EN;
    wire              S_AXI_HP2_WRISSUECAP1_EN;
    wire              S_AXI_HP3_RDISSUECAP1_EN;
    wire              S_AXI_HP3_WRISSUECAP1_EN;
    wire     [2 : 0]  S_AXI_HP3_RACOUNT       ;
    wire     [5 : 0]  S_AXI_HP3_WACOUNT       ;
    wire     [7 : 0]  S_AXI_HP3_RCOUNT        ;
    wire     [7 : 0]  S_AXI_HP3_WCOUNT        ;

    wire              S_AXI_HP2_ARREADY       ;
    wire              S_AXI_HP2_AWREADY       ;
    wire              S_AXI_HP2_BVALID        ;
    wire              S_AXI_HP2_RLAST         ;
    wire              S_AXI_HP2_RVALID        ;
    wire              S_AXI_HP2_WREADY        ;
    wire     [1 : 0]  S_AXI_HP2_BRESP         ;
    wire     [1 : 0]  S_AXI_HP2_RRESP         ;
    wire     [4 : 0]  S_AXI_HP2_BID           ;
    wire     [4 : 0]  S_AXI_HP2_RID           ;
    wire     [63 : 0] S_AXI_HP2_RDATA         ;
    wire     [7 : 0]  S_AXI_HP2_RCOUNT        ;
    wire     [7 : 0]  S_AXI_HP2_WCOUNT        ;
    wire     [2 : 0]  S_AXI_HP2_RACOUNT       ;
    wire     [5 : 0]  S_AXI_HP2_WACOUNT       ;
    wire              S_AXI_HP2_ARVALID       ;
    wire              S_AXI_HP2_AWVALID       ;
    wire              S_AXI_HP2_BREADY        ;
    wire              S_AXI_HP2_RREADY        ;
    wire              S_AXI_HP2_WLAST         ;
    wire              S_AXI_HP2_WVALID        ;
    wire    [1 : 0]   S_AXI_HP2_ARBURST       ;
    wire    [1 : 0]   S_AXI_HP2_ARLOCK        ;
    wire    [2 : 0]   S_AXI_HP2_ARSIZE        ;
    wire    [1 : 0]   S_AXI_HP2_AWBURST       ;
    wire    [1 : 0]   S_AXI_HP2_AWLOCK        ;
    wire    [2 : 0]   S_AXI_HP2_AWSIZE        ;
    wire    [2 : 0]   S_AXI_HP2_ARPROT        ;
    wire    [2 : 0]   S_AXI_HP2_AWPROT        ;
    wire    [31 : 0]  S_AXI_HP2_ARADDR        ;
    wire    [31 : 0]  S_AXI_HP2_AWADDR        ;
    wire    [3 : 0]   S_AXI_HP2_ARCACHE       ;
    wire    [3 : 0]   S_AXI_HP2_ARLEN         ;
    wire    [3 : 0]   S_AXI_HP2_ARQOS         ;
    wire    [3 : 0]   S_AXI_HP2_AWCACHE       ;
    wire    [3 : 0]   S_AXI_HP2_AWLEN         ;
    wire    [3 : 0]   S_AXI_HP2_AWQOS         ;
    wire    [4 : 0]   S_AXI_HP2_ARID          ;
    wire    [4 : 0]   S_AXI_HP2_AWID          ;
    wire    [4 : 0]   S_AXI_HP2_WID           ;
    wire    [63 : 0]  S_AXI_HP2_WDATA         ;
    wire    [7 : 0]   S_AXI_HP2_WSTRB         ;


    // HP_HC
    wire             S0_AXI_HP_HC_ARREADY     ;
    wire             S0_AXI_HP_HC_AWREADY     ;
    wire             S0_AXI_HP_HC_BVALID      ;
    wire             S0_AXI_HP_HC_RLAST       ;
    wire             S0_AXI_HP_HC_RVALID      ;
    wire             S0_AXI_HP_HC_WREADY      ;
    wire   [1 : 0  ] S0_AXI_HP_HC_BRESP       ;
    wire   [1 : 0  ] S0_AXI_HP_HC_RRESP       ;
    wire   [4 : 0  ] S0_AXI_HP_HC_BID         ;
    wire   [4 : 0  ] S0_AXI_HP_HC_RID         ;
    wire   [63: 0  ] S0_AXI_HP_HC_RDATA       ;
    wire             S0_AXI_HP_HC_ARVALID     ;
    wire             S0_AXI_HP_HC_AWVALID     ;
    wire             S0_AXI_HP_HC_BREADY      ;
    wire             S0_AXI_HP_HC_RREADY      ;
    wire             S0_AXI_HP_HC_WLAST       ;
    wire             S0_AXI_HP_HC_WVALID      ;
    wire   [1 : 0  ] S0_AXI_HP_HC_ARBURST     ;
    wire   [1 : 0  ] S0_AXI_HP_HC_ARLOCK      ;
    wire   [2 : 0  ] S0_AXI_HP_HC_ARSIZE      ;
    wire   [1 : 0  ] S0_AXI_HP_HC_AWBURST     ;
    wire   [1 : 0  ] S0_AXI_HP_HC_AWLOCK      ;
    wire   [2 : 0  ] S0_AXI_HP_HC_AWSIZE      ;
    wire   [2 : 0  ] S0_AXI_HP_HC_ARPROT      ;
    wire   [2 : 0  ] S0_AXI_HP_HC_AWPROT      ;
    wire   [31: 0  ] S0_AXI_HP_HC_ARADDR      ;
    wire   [31: 0  ] S0_AXI_HP_HC_AWADDR      ;
    wire   [3 : 0  ] S0_AXI_HP_HC_ARCACHE     ;
    wire   [3 : 0  ] S0_AXI_HP_HC_ARLEN       ;
    wire   [3 : 0  ] S0_AXI_HP_HC_ARQOS       ;
    wire   [3 : 0  ] S0_AXI_HP_HC_AWCACHE     ;
    wire   [3 : 0  ] S0_AXI_HP_HC_AWLEN       ;
    wire   [3 : 0  ] S0_AXI_HP_HC_AWQOS       ;
    wire   [4 : 0  ] S0_AXI_HP_HC_ARID        ;
    wire   [4 : 0  ] S0_AXI_HP_HC_AWID        ;
    wire   [4 : 0  ] S0_AXI_HP_HC_WID         ;
    wire   [63: 0  ] S0_AXI_HP_HC_WDATA       ;
    wire   [7 : 0  ] S0_AXI_HP_HC_WSTRB       ;    

    wire             S1_AXI_HP_HC_ARREADY     ;
    wire             S1_AXI_HP_HC_AWREADY     ;
    wire             S1_AXI_HP_HC_BVALID      ;
    wire             S1_AXI_HP_HC_RLAST       ;
    wire             S1_AXI_HP_HC_RVALID      ;
    wire             S1_AXI_HP_HC_WREADY      ;
    wire   [1 : 0  ] S1_AXI_HP_HC_BRESP       ;
    wire   [1 : 0  ] S1_AXI_HP_HC_RRESP       ;
    wire   [4 : 0  ] S1_AXI_HP_HC_BID         ;
    wire   [4 : 0  ] S1_AXI_HP_HC_RID         ;
    wire   [63: 0  ] S1_AXI_HP_HC_RDATA       ;
    wire             S1_AXI_HP_HC_ARVALID     ;
    wire             S1_AXI_HP_HC_AWVALID     ;
    wire             S1_AXI_HP_HC_BREADY      ;
    wire             S1_AXI_HP_HC_RREADY      ;
    wire             S1_AXI_HP_HC_WLAST       ;
    wire             S1_AXI_HP_HC_WVALID      ;
    wire   [1 : 0  ] S1_AXI_HP_HC_ARBURST     ;
    wire   [1 : 0  ] S1_AXI_HP_HC_ARLOCK      ;
    wire   [2 : 0  ] S1_AXI_HP_HC_ARSIZE      ;
    wire   [1 : 0  ] S1_AXI_HP_HC_AWBURST     ;
    wire   [1 : 0  ] S1_AXI_HP_HC_AWLOCK      ;
    wire   [2 : 0  ] S1_AXI_HP_HC_AWSIZE      ;
    wire   [2 : 0  ] S1_AXI_HP_HC_ARPROT      ;
    wire   [2 : 0  ] S1_AXI_HP_HC_AWPROT      ;
    wire   [31: 0  ] S1_AXI_HP_HC_ARADDR      ;
    wire   [31: 0  ] S1_AXI_HP_HC_AWADDR      ;
    wire   [3 : 0  ] S1_AXI_HP_HC_ARCACHE     ;
    wire   [3 : 0  ] S1_AXI_HP_HC_ARLEN       ;
    wire   [3 : 0  ] S1_AXI_HP_HC_ARQOS       ;
    wire   [3 : 0  ] S1_AXI_HP_HC_AWCACHE     ;
    wire   [3 : 0  ] S1_AXI_HP_HC_AWLEN       ;
    wire   [3 : 0  ] S1_AXI_HP_HC_AWQOS       ;
    wire   [4 : 0  ] S1_AXI_HP_HC_ARID        ;
    wire   [4 : 0  ] S1_AXI_HP_HC_AWID        ;
    wire   [4 : 0  ] S1_AXI_HP_HC_WID         ;
    wire   [63: 0  ] S1_AXI_HP_HC_WDATA       ;
    wire   [7 : 0  ] S1_AXI_HP_HC_WSTRB       ; 

    wire             S2_AXI_HP_HC_ARREADY     ;
    wire             S2_AXI_HP_HC_AWREADY     ;
    wire             S2_AXI_HP_HC_BVALID      ;
    wire             S2_AXI_HP_HC_RLAST       ;
    wire             S2_AXI_HP_HC_RVALID      ;
    wire             S2_AXI_HP_HC_WREADY      ;
    wire   [1 : 0  ] S2_AXI_HP_HC_BRESP       ;
    wire   [1 : 0  ] S2_AXI_HP_HC_RRESP       ;
    wire   [4 : 0  ] S2_AXI_HP_HC_BID         ;
    wire   [4 : 0  ] S2_AXI_HP_HC_RID         ;
    wire   [63: 0  ] S2_AXI_HP_HC_RDATA       ;
    wire             S2_AXI_HP_HC_ARVALID     ;
    wire             S2_AXI_HP_HC_AWVALID     ;
    wire             S2_AXI_HP_HC_BREADY      ;
    wire             S2_AXI_HP_HC_RREADY      ;
    wire             S2_AXI_HP_HC_WLAST       ;
    wire             S2_AXI_HP_HC_WVALID      ;
    wire   [1 : 0  ] S2_AXI_HP_HC_ARBURST     ;
    wire   [1 : 0  ] S2_AXI_HP_HC_ARLOCK      ;
    wire   [2 : 0  ] S2_AXI_HP_HC_ARSIZE      ;
    wire   [1 : 0  ] S2_AXI_HP_HC_AWBURST     ;
    wire   [1 : 0  ] S2_AXI_HP_HC_AWLOCK      ;
    wire   [2 : 0  ] S2_AXI_HP_HC_AWSIZE      ;
    wire   [2 : 0  ] S2_AXI_HP_HC_ARPROT      ;
    wire   [2 : 0  ] S2_AXI_HP_HC_AWPROT      ;
    wire   [31: 0  ] S2_AXI_HP_HC_ARADDR      ;
    wire   [31: 0  ] S2_AXI_HP_HC_AWADDR      ;
    wire   [3 : 0  ] S2_AXI_HP_HC_ARCACHE     ;
    wire   [3 : 0  ] S2_AXI_HP_HC_ARLEN       ;
    wire   [3 : 0  ] S2_AXI_HP_HC_ARQOS       ;
    wire   [3 : 0  ] S2_AXI_HP_HC_AWCACHE     ;
    wire   [3 : 0  ] S2_AXI_HP_HC_AWLEN       ;
    wire   [3 : 0  ] S2_AXI_HP_HC_AWQOS       ;
    wire   [4 : 0  ] S2_AXI_HP_HC_ARID        ;
    wire   [4 : 0  ] S2_AXI_HP_HC_AWID        ;
    wire   [4 : 0  ] S2_AXI_HP_HC_WID         ;
    wire   [63: 0  ] S2_AXI_HP_HC_WDATA       ;
    wire   [7 : 0  ] S2_AXI_HP_HC_WSTRB       ; 

    wire             S3_AXI_HP_HC_ARREADY     ;
    wire             S3_AXI_HP_HC_AWREADY     ;
    wire             S3_AXI_HP_HC_BVALID      ;
    wire             S3_AXI_HP_HC_RLAST       ;
    wire             S3_AXI_HP_HC_RVALID      ;
    wire             S3_AXI_HP_HC_WREADY      ;
    wire   [1 : 0  ] S3_AXI_HP_HC_BRESP       ;
    wire   [1 : 0  ] S3_AXI_HP_HC_RRESP       ;
    wire   [4 : 0  ] S3_AXI_HP_HC_BID         ;
    wire   [4 : 0  ] S3_AXI_HP_HC_RID         ;
    wire   [63: 0  ] S3_AXI_HP_HC_RDATA       ;
    wire             S3_AXI_HP_HC_ARVALID     ;
    wire             S3_AXI_HP_HC_AWVALID     ;
    wire             S3_AXI_HP_HC_BREADY      ;
    wire             S3_AXI_HP_HC_RREADY      ;
    wire             S3_AXI_HP_HC_WLAST       ;
    wire             S3_AXI_HP_HC_WVALID      ;
    wire   [1 : 0  ] S3_AXI_HP_HC_ARBURST     ;
    wire   [1 : 0  ] S3_AXI_HP_HC_ARLOCK      ;
    wire   [2 : 0  ] S3_AXI_HP_HC_ARSIZE      ;
    wire   [1 : 0  ] S3_AXI_HP_HC_AWBURST     ;
    wire   [1 : 0  ] S3_AXI_HP_HC_AWLOCK      ;
    wire   [2 : 0  ] S3_AXI_HP_HC_AWSIZE      ;
    wire   [2 : 0  ] S3_AXI_HP_HC_ARPROT      ;
    wire   [2 : 0  ] S3_AXI_HP_HC_AWPROT      ;
    wire   [31: 0  ] S3_AXI_HP_HC_ARADDR      ;
    wire   [31: 0  ] S3_AXI_HP_HC_AWADDR      ;
    wire   [3 : 0  ] S3_AXI_HP_HC_ARCACHE     ;
    wire   [3 : 0  ] S3_AXI_HP_HC_ARLEN       ;
    wire   [3 : 0  ] S3_AXI_HP_HC_ARQOS       ;
    wire   [3 : 0  ] S3_AXI_HP_HC_AWCACHE     ;
    wire   [3 : 0  ] S3_AXI_HP_HC_AWLEN       ;
    wire   [3 : 0  ] S3_AXI_HP_HC_AWQOS       ;
    wire   [4 : 0  ] S3_AXI_HP_HC_ARID        ;
    wire   [4 : 0  ] S3_AXI_HP_HC_AWID        ;
    wire   [4 : 0  ] S3_AXI_HP_HC_WID         ;
    wire   [63: 0  ] S3_AXI_HP_HC_WDATA       ;
    wire   [7 : 0  ] S3_AXI_HP_HC_WSTRB       ;    

    wire              FCLK_RESET0_N           ;

    wire    [28 : 0 ] app_addr                ;
    wire    [2 : 0  ] app_cmd                 ;
    wire              app_en                  ;
    wire [64*8-1 : 0] app_wdf_data            ;
    wire [64-1   : 0] app_wdf_mask            ;
    wire [64*8-1 : 0] app_rd_data             ;
    wire              app_wdf_end             ;
    wire              app_wdf_wren            ;
    wire              app_rd_data_end         ; 
    wire              app_rd_data_valid       ; 
    wire              app_rdy                 ; 
    wire              app_wdf_rdy             ; 

  // ************************************************************************************
  //   reset and clocks
  // ************************************************************************************
  wire              soft_rst            ;
  wire              sys_rst_n           ;
  wire              clk_200mhz          ;
  wire              ddr_clk_rst         ;
  wire              ps_clk_out          ;  
  wire              ddr_clk             ;
  wire              ddr_ui_rst          ; // not use
  wire              ddr3_init_done      ;
  wire              ddr_clk_led         ;
  wire              ps_clk_led          ;

  // ************************************************************************************
  //   cam & display
  // ************************************************************************************
  wire              cmos_vsync_out      ;
  wire              cmos_href_out       ;
  wire  [23:0]      cmos_db_out         ; 
  wire  [1 :0]      write_addr_index    ;
  wire  [1 :0]      read_addr_index     ;    
  wire              continuous_en       ;
  wire              img_start           ;
  wire  [23:0]      img_data            ;
  wire              img_valid           ;
  wire              img_ready           ;  
  wire              img_start0          ;
  wire  [23:0]      img_data0           ;
  wire              img_valid0          ;
  wire              img_ready0          ;  
  wire              img_start1          ;
  wire  [23:0]      img_data1           ;
  wire              img_valid1          ;
  wire              img_ready1          ;
  wire              reset_cam_clk       ;

  wire  [15 : 0]    ps_x0_pos           ;
  wire  [15 : 0]    ps_y0_pos           ;
  wire  [15 : 0]    ps_x1_pos           ;
  wire  [15 : 0]    ps_y1_pos           ;
  wire  [15 : 0]    ps_x_leng           ;
  wire  [15 : 0]    ps_y_leng           ;
  wire  [ 3 : 0]    ps_hstride          ;
  wire  [ 3 : 0]    ps_vstride          ;
  wire  [10 : 0]    resize_pix_len      ;
  wire  [31 : 0]    write_ps_size       ;
  // Display (HDMI readback) geometry -- independent of the capture geometry.
  wire  [15 : 0]    disp_x_leng         ;
  wire  [15 : 0]    disp_y_leng         ;
  wire  [31 : 0]    disp_ps_size        ;
  wire              display_en          ;

  wire  [31 : 0]    camera_wr_addr      ;
  wire  [31 : 0]    camera_rd_addr      ;
  wire              wr_done_pulse       ;
     
  wire              wr_wfifo_err        ;
  wire              rd_rfifo_err        ;

  wire              test_irq            ;
  wire              customop_irq        ;
  wire              ai_irq              ; 
  wire              pl_bist_err_inv     ; 
  wire              dip_switches        ;
  wire              pl_bvalid           ;
  wire              pl_bready           ;
  wire              pll_lock            ; 
  wire    [23:0]    vtc_data            ;
  wire              vtc_vs              ;
  wire              vtc_hs              ;
  wire              vtc_de              ;

  wire    [31 : 0]  H_SYNC              ;
  wire    [31 : 0]  H_BACK_PORCH        ;
  wire    [31 : 0]  H_ACTIVE            ;
  wire    [31 : 0]  H_FRONT_PORCH       ;
  wire    [31 : 0]  V_SYNC              ;
  wire    [31 : 0]  V_BACK_PORCH        ;
  wire    [31 : 0]  V_ACTIVE            ;
  wire    [31 : 0]  V_FRONT_PORCH       ;

  //************************************

  mna_gp_ww_itf  gp0();
  mna_gp_ww_itf  gp1();
  mna_gp_ww_itf  host_ctrl()  ;
  mna_gp_ww_itf  ai_ra()      ;
  mna_gp_ww_itf  cam()        ;
  mna_gp_ww_itf  user_op()    ;

  assign sys_rst_n    = ~sys_rst                   ;
  assign led[0]     = ddr3_init_done & ddr_clk_led ;
  assign led[1]     = led3                         ;
  assign dip_switches = 1'b1;


demo_clkrst_wrapper u_demo_clkrst_wrapper(
  .ddr_clk_led (ddr_clk_led ),
  .ps_clk_led  (ps_clk_led  ),

  .sys_rst     (sys_rst | (~FCLK_RESET0_N)),
  .soft_rst    (soft_rst    ),

  .ddr_clk     (ddr_clk     ),
  .ps_clk_out  (ps_clk_out  ),

  .gp_clk      (gp_clk      ),
  .hp_clk      (hp_clk      ),
  .gp_clk_rst  (gp_clk_rst  ),
  .hp_clk_rst  (hp_clk_rst  ),
  .ddr_clk_rst (ddr_clk_rst )
);

gp_io u_gp0_io(
  .M_AXI_GP_ARVALID (User_GP0_ARVALID ),
  .M_AXI_GP_AWVALID (User_GP0_AWVALID ),
  .M_AXI_GP_BREADY  (User_GP0_BREADY  ),
  .M_AXI_GP_RREADY  (User_GP0_RREADY  ),
  .M_AXI_GP_WLAST   (User_GP0_WLAST   ),
  .M_AXI_GP_WVALID  (User_GP0_WVALID  ),
  .M_AXI_GP_ARID    (User_GP0_ARID    ),
  .M_AXI_GP_AWID    (User_GP0_AWID    ),
  .M_AXI_GP_WID     (User_GP0_WID     ),
  .M_AXI_GP_ARBURST (User_GP0_ARBURST ),
  .M_AXI_GP_ARLOCK  (User_GP0_ARLOCK  ),
  .M_AXI_GP_ARSIZE  (User_GP0_ARSIZE  ),
  .M_AXI_GP_AWBURST (User_GP0_AWBURST ),
  .M_AXI_GP_AWLOCK  (User_GP0_AWLOCK  ),
  .M_AXI_GP_AWSIZE  (User_GP0_AWSIZE  ),
  .M_AXI_GP_ARPROT  (User_GP0_ARPROT  ),
  .M_AXI_GP_AWPROT  (User_GP0_AWPROT  ),
  .M_AXI_GP_ARADDR  (User_GP0_ARADDR  ),
  .M_AXI_GP_AWADDR  (User_GP0_AWADDR  ),
  .M_AXI_GP_WDATA   (User_GP0_WDATA   ),
  .M_AXI_GP_ARCACHE (User_GP0_ARCACHE ),
  .M_AXI_GP_ARLEN   (User_GP0_ARLEN   ),
  .M_AXI_GP_ARQOS   (User_GP0_ARQOS   ),
  .M_AXI_GP_AWCACHE (User_GP0_AWCACHE ),
  .M_AXI_GP_AWLEN   (User_GP0_AWLEN   ),
  .M_AXI_GP_AWQOS   (User_GP0_AWQOS   ),
  .M_AXI_GP_WSTRB   (User_GP0_WSTRB   ),
  .M_AXI_GP_ACLK    (User_GP0_ACLK    ),
  .M_AXI_GP_ARREADY (User_GP0_ARREADY ),
  .M_AXI_GP_AWREADY (User_GP0_AWREADY ),
  .M_AXI_GP_BVALID  (User_GP0_BVALID  ),
  .M_AXI_GP_RLAST   (User_GP0_RLAST   ),
  .M_AXI_GP_RVALID  (User_GP0_RVALID  ),
  .M_AXI_GP_WREADY  (User_GP0_WREADY  ),
  .M_AXI_GP_BID     (User_GP0_BID     ),
  .M_AXI_GP_RID     (User_GP0_RID     ),
  .M_AXI_GP_BRESP   (User_GP0_BRESP   ),
  .M_AXI_GP_RRESP   (User_GP0_RRESP   ),
  .M_AXI_GP_RDATA   (User_GP0_RDATA   ),
  .gp               (gp0.master       ),
  .gp_clk_rst       (gp_clk_rst       ),
  .gp_clk           (gp_clk           )
);

gp0_manager 
#(
  .GP0_BASE       (32'h40000000       )
)
u_gp0_manager(
  .gpx       (gp0.slave            ),
  .host_ctrl (host_ctrl.master     ), // not used
  .ai_ra     (ai_ra.master         ), // not used
  .m2_gpx    (cam.master           ),
  .m3_gpx    (user_op.master       ),
  .gpx_rst   (gp_clk_rst           ),
  .gpx_clk   (gp_clk               )
);

gpx_RFU  #(.ERR(32'hA0AAAAAA)) u_host_ctrl_RFU(
  .gpx             (host_ctrl.slave            ),    
  .gpx_rst         (gp_clk_rst                 ),
  .gpx_clk         (gp_clk                     )
);

gpx_RFU  #(.ERR(32'hA0AAAAAA)) u_ai_ra_RFU(
  .gpx             (ai_ra.slave                ),    
  .gpx_rst         (gp_clk_rst                 ),
  .gpx_clk         (gp_clk                     )
);

assign User_Reg_araddr   = user_op.araddr   ;   
assign User_Reg_arvalid  = user_op.arvalid  ; 
assign User_Reg_rready   = user_op.rready   ;   
assign User_Reg_awwaddr  = user_op.awwaddr  ;   
assign User_Reg_awwdata  = user_op.awwdata  ;   
assign User_Reg_awwvalid = user_op.awwvalid ;   
assign user_op.arready   = User_Reg_arready  ;
assign user_op.rdata     = User_Reg_rdata    ;
assign user_op.rvalid    = User_Reg_rvalid   ;
assign user_op.awwready  = User_Reg_awwready ;

gp_io u_gp1_io(
  .M_AXI_GP_ARVALID (User_GP1_ARVALID  ),
  .M_AXI_GP_AWVALID (User_GP1_AWVALID  ),
  .M_AXI_GP_BREADY  (User_GP1_BREADY   ),
  .M_AXI_GP_RREADY  (User_GP1_RREADY   ),
  .M_AXI_GP_WLAST   (User_GP1_WLAST    ),
  .M_AXI_GP_WVALID  (User_GP1_WVALID   ),
  .M_AXI_GP_ARID    (User_GP1_ARID     ),
  .M_AXI_GP_AWID    (User_GP1_AWID     ),
  .M_AXI_GP_WID     (User_GP1_WID      ),
  .M_AXI_GP_ARBURST (User_GP1_ARBURST  ),
  .M_AXI_GP_ARLOCK  (User_GP1_ARLOCK   ),
  .M_AXI_GP_ARSIZE  (User_GP1_ARSIZE   ),
  .M_AXI_GP_AWBURST (User_GP1_AWBURST  ),
  .M_AXI_GP_AWLOCK  (User_GP1_AWLOCK   ),
  .M_AXI_GP_AWSIZE  (User_GP1_AWSIZE   ),
  .M_AXI_GP_ARPROT  (User_GP1_ARPROT   ),
  .M_AXI_GP_AWPROT  (User_GP1_AWPROT   ),
  .M_AXI_GP_ARADDR  (User_GP1_ARADDR   ),
  .M_AXI_GP_AWADDR  (User_GP1_AWADDR   ),
  .M_AXI_GP_WDATA   (User_GP1_WDATA    ),
  .M_AXI_GP_ARCACHE (User_GP1_ARCACHE  ),
  .M_AXI_GP_ARLEN   (User_GP1_ARLEN    ),
  .M_AXI_GP_ARQOS   (User_GP1_ARQOS    ),
  .M_AXI_GP_AWCACHE (User_GP1_AWCACHE  ),
  .M_AXI_GP_AWLEN   (User_GP1_AWLEN    ),
  .M_AXI_GP_AWQOS   (User_GP1_AWQOS    ),
  .M_AXI_GP_WSTRB   (User_GP1_WSTRB    ),
  .M_AXI_GP_ACLK    (User_GP1_ACLK     ),
  .M_AXI_GP_ARREADY (User_GP1_ARREADY  ),
  .M_AXI_GP_AWREADY (User_GP1_AWREADY  ),
  .M_AXI_GP_BVALID  (User_GP1_BVALID   ),
  .M_AXI_GP_RLAST   (User_GP1_RLAST    ),
  .M_AXI_GP_RVALID  (User_GP1_RVALID   ),
  .M_AXI_GP_WREADY  (User_GP1_WREADY   ),
  .M_AXI_GP_BID     (User_GP1_BID      ),
  .M_AXI_GP_RID     (User_GP1_RID      ),
  .M_AXI_GP_BRESP   (User_GP1_BRESP    ),
  .M_AXI_GP_RRESP   (User_GP1_RRESP    ),
  .M_AXI_GP_RDATA   (User_GP1_RDATA    ),
  .gp               (gp1.master        ),
  .gp_clk_rst       (gp_clk_rst        ),
  .gp_clk           (gp_clk            )
);

gpx_RFU  #(.ERR(32'hB0AAAAAA)) u_cdma_ctrl_RFU(
  .gpx             (gp1.slave                 ),    
  .gpx_rst         (gp_clk_rst                ),
  .gpx_clk         (gp_clk                    )
);

async_to_sync_reset async_reset_100MHz(
  .async_reset            (~pll_lock         ),
  .clk                    (gp_clk            ),
  .sync_reset             (reset_100mhz      )
); 

async_to_sync_reset a2sync_reset_cam0_clk(
	.async_reset            (~pll_lock         ),
	.clk                    (cam_clk           ),
	.sync_reset             (reset_cam_clk     )
);

vtc u_vtc(
    .clk           ( cam_clk         ),
    .rst_n         ( ~reset_cam_clk  ),

    .H_SYNC        (H_SYNC           ),
    .H_BACK_PORCH  (H_BACK_PORCH     ),
    .H_ACTIVE      (H_ACTIVE         ),
    .H_FRONT_PORCH (H_FRONT_PORCH    ),
    .V_SYNC        (V_SYNC           ),
    .V_BACK_PORCH  (V_BACK_PORCH     ),
    .V_ACTIVE      (V_ACTIVE        ),
    .V_FRONT_PORCH (V_FRONT_PORCH    ),  

    .data          ( vtc_data        ),
    .vs            ( vtc_vs          ),
    .hs            ( vtc_hs          ),
    .de            ( vtc_de          ) 
);

frame_to_ps_largebuf frame_to_ps_inst0(
    .cam_clk_use           (cam_clk              ),
    .reset_cam_clk         (reset_cam_clk        ),  
 
    // SDI receiver status -> the frame path's status writer -> DDR. Needed
    // because the NPU register route does not build on this board.
    .sdi_status_bus        (sdi_status_bus       ),

    .cmos_vsync_out        (cmos_vsync_out       ),
    .cmos_href_out         (cmos_href_out        ),
    .cmos_db_out           (cmos_db_out          ),    

    .display_en            (display_en            ),

    .reset_100mhz_n        (!reset_100mhz         ),
	  .HDMI_CLK_P            (HDMI_CLK_P            ),   
    .HDMI_CLK_N            (HDMI_CLK_N            ),
    .HDMI_TX_P             (HDMI_TX_P             ),
    .HDMI_TX_N             (HDMI_TX_N             ),   
        
    // master axi interface, connect HP 
    .m00_axi_aclk          (hp_clk               ),
    .m00_axi_aresetn       (~hp_clk_rst          ),
    .m00_axi_awid          (S_AXI_HP2_AWID        ),
    .m00_axi_awaddr        (S_AXI_HP2_AWADDR      ),
    .m00_axi_awlen         (S_AXI_HP2_AWLEN       ),
    .m00_axi_awsize        (S_AXI_HP2_AWSIZE      ),
    .m00_axi_awburst       (S_AXI_HP2_AWBURST     ),       
    .m00_axi_awlock        (S_AXI_HP2_AWLOCK      ),   
    .m00_axi_awcache       (S_AXI_HP2_AWCACHE     ),  
    .m00_axi_awprot        (S_AXI_HP2_AWPROT      ),   
    .m00_axi_awqos         (S_AXI_HP2_AWQOS       ),    
    .m00_axi_awuser        (                      ),  
    .m00_axi_awvalid       (S_AXI_HP2_AWVALID     ),
    .m00_axi_awready       (S_AXI_HP2_AWREADY     ),
	       
    .m00_axi_wdata         (S_AXI_HP2_WDATA       ),
    .m00_axi_wstrb         (S_AXI_HP2_WSTRB       ),
    .m00_axi_wlast         (S_AXI_HP2_WLAST       ),
    .m00_axi_wuser         (                      ),
    .m00_axi_wvalid        (S_AXI_HP2_WVALID      ),
    .m00_axi_wready        (S_AXI_HP2_WREADY      ),
	       
    .m00_axi_bid           (S_AXI_HP2_BID         ),
    .m00_axi_bresp         (S_AXI_HP2_BRESP       ),
    .m00_axi_buser         (1'b0                  ),
    .m00_axi_bvalid        (S_AXI_HP2_BVALID      ),
    .m00_axi_bready        (S_AXI_HP2_BREADY      ),
	       
    .m00_axi_arid          (S_AXI_HP2_ARID        ),
    .m00_axi_araddr        (S_AXI_HP2_ARADDR      ),
    .m00_axi_arlen         (S_AXI_HP2_ARLEN       ),
    .m00_axi_arsize        (S_AXI_HP2_ARSIZE      ),
    .m00_axi_arburst       (S_AXI_HP2_ARBURST     ),
    .m00_axi_arlock        (S_AXI_HP2_ARLOCK      ),
    .m00_axi_arcache       (S_AXI_HP2_ARCACHE     ),
    .m00_axi_arprot        (S_AXI_HP2_ARPROT      ),
    .m00_axi_arqos         (S_AXI_HP2_ARQOS       ),
    .m00_axi_aruser        (                      ),
    .m00_axi_arvalid       (S_AXI_HP2_ARVALID     ),
    .m00_axi_arready       (S_AXI_HP2_ARREADY     ),
	           
    .m00_axi_rid           (S_AXI_HP2_RID         ),
    .m00_axi_rdata         (S_AXI_HP2_RDATA       ),
    .m00_axi_rresp         (S_AXI_HP2_RRESP       ),
    .m00_axi_rlast         (S_AXI_HP2_RLAST       ),
    .m00_axi_ruser         (1'b0                  ),
    .m00_axi_rvalid        (S_AXI_HP2_RVALID      ),
    .m00_axi_rready        (S_AXI_HP2_RREADY      ), 

    //ps rsize config
    .ps_x0_pos             (ps_x0_pos            ),
    .ps_y0_pos             (ps_y0_pos            ),
    .ps_x1_pos             (ps_x1_pos            ),
    .ps_y1_pos             (ps_y1_pos            ),
    .ps_x_leng             (ps_x_leng            ),
    .ps_y_leng             (ps_y_leng            ),
    .ps_hstride            (ps_hstride           ),
    .ps_vstride            (ps_vstride           ),
    .resize_pix_len        (resize_pix_len       ),			
    .write_ps_size         (write_ps_size        ),
    .disp_ps_size          (disp_ps_size         ),
    .disp_x_leng           (disp_x_leng          ),
    .disp_y_leng           (disp_y_leng          ),

    .camera_wr_addr       (camera_wr_addr        ),
    .camera_rd_addr       (camera_rd_addr        ),
    .wr_wfifo_err         (wr_wfifo_err          ),
    .rd_rfifo_err         (rd_rfifo_err          ),
    .wr_done_pulse        (wr_done_pulse         ), 
    .dip_switches         (dip_switches          ),
    .ch0_write_addr_index (write_addr_index      ),
    .ch0_read_addr_index  (read_addr_index       )  
 );

 assign S_AXI_HP2_RDISSUECAP1_EN = 1'b0;
 assign S_AXI_HP2_WRISSUECAP1_EN = 1'b0;
 assign S_AXI_HP2_WID = 6'h00;

frame_trans frame_trans_inst0(
    // cmos
    .cam_vs              (cam_vs                ),
    .cam_de              (cam_data_en           ),
    .cam_rgb             (cam_rgb               ),
    .vtc_vs              (vtc_vs                ),
    .vtc_de              (vtc_de                ),
    .vtc_data            (vtc_data              ),
    
    .cam_clk             (cam_clk               ),
		.reset_cam_clk       (reset_cam_clk         ),

    .sdi_status_bus      (sdi_status_bus        ),
         
    .cmos_vsync_out      (cmos_vsync_out        ),
    .cmos_href_out       (cmos_href_out         ),
    .cmos_db_out         (cmos_db_out           ),  

    // slave axi lite interface
    .S_AXI_ACLK          (gp_clk                ),//50M
    .S_AXI_ARESETN       (~gp_clk_rst           ),
    .cam                 (cam.slave             ),	 

    //ps rsize config
    .ps_x0_pos           (ps_x0_pos             ),
    .ps_y0_pos           (ps_y0_pos             ),
    .ps_x1_pos           (ps_x1_pos             ),
    .ps_y1_pos           (ps_y1_pos             ),
    .ps_x_leng           (ps_x_leng             ),
    .ps_y_leng           (ps_y_leng             ),
    .ps_hstride          (ps_hstride            ),
    .ps_vstride          (ps_vstride            ),	
    .resize_pix_len      (resize_pix_len        ),			
    .write_ps_size       (write_ps_size         ),
    .disp_x_leng         (disp_x_leng           ),
    .disp_y_leng         (disp_y_leng           ),
    .disp_ps_size        (disp_ps_size          ),
    .H_SYNC              (H_SYNC                ),
    .H_BACK_PORCH        (H_BACK_PORCH          ),
    .H_ACTIVE            (H_ACTIVE              ),
    .H_FRONT_PORCH       (H_FRONT_PORCH         ),
    .V_SYNC              (V_SYNC                ),
    .V_BACK_PORCH        (V_BACK_PORCH          ),
    .V_ACTIVE            (V_ACTIVE              ),
    .V_FRONT_PORCH       (V_FRONT_PORCH         ),      

    //img_data for image_make 
    .M01_AXI_ACLK        (ddr_clk               ),
    .M01_AXI_ARESETN     (~ddr_clk_rst          ),    
    .img_start           (img_start1            ),
    .img_data            (img_data1             ),
    .img_valid           (img_valid1            ),
    .img_ready           (img_ready1            ),  

    //frame mode 
    .continuous_en       (continuous_en         ),  
    .display_en          (display_en            ),
    .wr_done_pulse       (wr_done_pulse         ),
    .wr_wfifo_err        (wr_wfifo_err          ),
    .rd_rfifo_err        (rd_rfifo_err          ),
    .camera_wr_addr      (camera_wr_addr        ),
    .camera_rd_addr      (camera_rd_addr        ),
  
    .irq_test            (test_irq              ),
    .write_addr_index    (write_addr_index      ),
    .read_addr_index     (read_addr_index       ),
    .sys_rst_n           (sys_rst_n & FCLK_RESET0_N ),
    .soft_rst            (soft_rst              )         
);

assign S_AXI_HP0_RDISSUECAP1_EN = 1'b0;
assign S_AXI_HP0_WRISSUECAP1_EN = 1'b0;
assign S_AXI_HP1_RDISSUECAP1_EN = 1'b0;
assign S_AXI_HP1_WRISSUECAP1_EN = 1'b0;
assign S_AXI_HP3_RDISSUECAP1_EN = 1'b0;
assign S_AXI_HP3_WRISSUECAP1_EN = 1'b0;

ps_ai_wrapper ps_ai_wrapper_u0 (
    .FIXED_IO_mio              (FIXED_IO_0_mio         ),
    .FIXED_IO_ps_srstb         (FIXED_IO_0_ps_srstb    ),
    .FIXED_IO_ps_clk           (FIXED_IO_0_ps_clk      ),
    .FIXED_IO_ps_porb          (FIXED_IO_0_ps_porb     ),
    .DDR_ck_p                  (DDR_0_ck_p             ),
    .DDR_ck_n                  (DDR_0_ck_n             ),
    .DDR_cke                   (DDR_0_cke              ),
    .DDR_cs_n                  (DDR_0_cs_n             ),
    .DDR_ras_n                 (DDR_0_ras_n            ),
    .DDR_cas_n                 (DDR_0_cas_n            ),
    .DDR_we_n                  (DDR_0_we_n             ),
    .DDR_ba                    (DDR_0_ba               ),
    .DDR_addr                  (DDR_0_addr             ),
    .DDR_odt                   (DDR_0_odt              ),
    .DDR_reset_n               (DDR_0_reset_n          ),
    .DDR_dq                    (DDR_0_dq               ),
    .DDR_dm                    (DDR_0_dm               ),
    .DDR_dqs_p                 (DDR_0_dqs_p            ),
    .DDR_dqs_n                 (DDR_0_dqs_n            ),
    .FIXED_IO_ddr_vrn          (FIXED_IO_0_ddr_vrn     ),
    .FIXED_IO_ddr_vrp          (FIXED_IO_0_ddr_vrp     ),
      
    .reset_n                   (sys_rst_n & FCLK_RESET0_N ), 
    .FCLK_RESET0_N             (FCLK_RESET0_N          ),
    .soft_rst_n                (~soft_rst              ),
      
    .PJTAG_TCK                 (PJTAG_TCK              ),
    .PJTAG_TMS                 (PJTAG_TMS              ),
    .PJTAG_TDI                 (PJTAG_TDI              ),
    .PJTAG_TDO                 (PJTAG_TDO              ), 
            
    .hp_axi_aclk               (hp_clk                 ),
    .ps_clk_out                (ps_clk_out             ),
    .pll_lock                  (pll_lock               ),
      
    .BYolo_GP0_ARVALID         (BYolo_GP0_ARVALID      ),
    .BYolo_GP0_AWVALID         (BYolo_GP0_AWVALID      ),
    .BYolo_GP0_BREADY          (BYolo_GP0_BREADY       ),
    .BYolo_GP0_RREADY          (BYolo_GP0_RREADY       ),
    .BYolo_GP0_WLAST           (BYolo_GP0_WLAST        ),
    .BYolo_GP0_WVALID          (BYolo_GP0_WVALID       ),
    .BYolo_GP0_ARID            (BYolo_GP0_ARID         ),
    .BYolo_GP0_AWID            (BYolo_GP0_AWID         ),
    .BYolo_GP0_WID             (BYolo_GP0_WID          ),
    .BYolo_GP0_ARBURST         (BYolo_GP0_ARBURST      ),
    .BYolo_GP0_ARLOCK          (BYolo_GP0_ARLOCK       ),
    .BYolo_GP0_ARSIZE          (BYolo_GP0_ARSIZE       ),
    .BYolo_GP0_AWBURST         (BYolo_GP0_AWBURST      ),
    .BYolo_GP0_AWLOCK          (BYolo_GP0_AWLOCK       ),
    .BYolo_GP0_AWSIZE          (BYolo_GP0_AWSIZE       ),
    .BYolo_GP0_ARPROT          (BYolo_GP0_ARPROT       ),
    .BYolo_GP0_AWPROT          (BYolo_GP0_AWPROT       ),
    .BYolo_GP0_ARADDR          (BYolo_GP0_ARADDR       ),
    .BYolo_GP0_AWADDR          (BYolo_GP0_AWADDR       ),
    .BYolo_GP0_WDATA           (BYolo_GP0_WDATA        ),
    .BYolo_GP0_ARCACHE         (BYolo_GP0_ARCACHE      ),
    .BYolo_GP0_ARLEN           (BYolo_GP0_ARLEN        ),
    .BYolo_GP0_ARQOS           (BYolo_GP0_ARQOS        ),
    .BYolo_GP0_AWCACHE         (BYolo_GP0_AWCACHE      ),
    .BYolo_GP0_AWLEN           (BYolo_GP0_AWLEN        ),
    .BYolo_GP0_AWQOS           (BYolo_GP0_AWQOS        ),
    .BYolo_GP0_WSTRB           (BYolo_GP0_WSTRB        ),
    .BYolo_GP0_ARREADY         (BYolo_GP0_ARREADY      ),
    .BYolo_GP0_AWREADY         (BYolo_GP0_AWREADY      ),
    .BYolo_GP0_BVALID          (BYolo_GP0_BVALID       ),
    .BYolo_GP0_RLAST           (BYolo_GP0_RLAST        ),
    .BYolo_GP0_RVALID          (BYolo_GP0_RVALID       ),
    .BYolo_GP0_WREADY          (BYolo_GP0_WREADY       ),
    .BYolo_GP0_BID             (BYolo_GP0_BID          ),
    .BYolo_GP0_RID             (BYolo_GP0_RID          ),
    .BYolo_GP0_BRESP           (BYolo_GP0_BRESP        ),
    .BYolo_GP0_RRESP           (BYolo_GP0_RRESP        ),
    .BYolo_GP0_RDATA           (BYolo_GP0_RDATA        ),
          
    .BYolo_GP1_ARVALID         (BYolo_GP1_ARVALID      ),
    .BYolo_GP1_AWVALID         (BYolo_GP1_AWVALID      ),
    .BYolo_GP1_BREADY          (BYolo_GP1_BREADY       ),
    .BYolo_GP1_RREADY          (BYolo_GP1_RREADY       ),
    .BYolo_GP1_WLAST           (BYolo_GP1_WLAST        ),
    .BYolo_GP1_WVALID          (BYolo_GP1_WVALID       ),
    .BYolo_GP1_ARID            (BYolo_GP1_ARID         ),
    .BYolo_GP1_AWID            (BYolo_GP1_AWID         ),
    .BYolo_GP1_WID             (BYolo_GP1_WID          ),
    .BYolo_GP1_ARBURST         (BYolo_GP1_ARBURST      ),
    .BYolo_GP1_ARLOCK          (BYolo_GP1_ARLOCK       ),
    .BYolo_GP1_ARSIZE          (BYolo_GP1_ARSIZE       ),
    .BYolo_GP1_AWBURST         (BYolo_GP1_AWBURST      ),
    .BYolo_GP1_AWLOCK          (BYolo_GP1_AWLOCK       ),
    .BYolo_GP1_AWSIZE          (BYolo_GP1_AWSIZE       ),
    .BYolo_GP1_ARPROT          (BYolo_GP1_ARPROT       ),
    .BYolo_GP1_AWPROT          (BYolo_GP1_AWPROT       ),
    .BYolo_GP1_ARADDR          (BYolo_GP1_ARADDR       ),
    .BYolo_GP1_AWADDR          (BYolo_GP1_AWADDR       ),
    .BYolo_GP1_WDATA           (BYolo_GP1_WDATA        ),
    .BYolo_GP1_ARCACHE         (BYolo_GP1_ARCACHE      ),
    .BYolo_GP1_ARLEN           (BYolo_GP1_ARLEN        ),
    .BYolo_GP1_ARQOS           (BYolo_GP1_ARQOS        ),
    .BYolo_GP1_AWCACHE         (BYolo_GP1_AWCACHE      ),
    .BYolo_GP1_AWLEN           (BYolo_GP1_AWLEN        ),
    .BYolo_GP1_AWQOS           (BYolo_GP1_AWQOS        ),
    .BYolo_GP1_WSTRB           (BYolo_GP1_WSTRB        ),
    .BYolo_GP1_ARREADY         (BYolo_GP1_ARREADY      ),
    .BYolo_GP1_AWREADY         (BYolo_GP1_AWREADY      ),
    .BYolo_GP1_BVALID          (BYolo_GP1_BVALID       ),
    .BYolo_GP1_RLAST           (BYolo_GP1_RLAST        ),
    .BYolo_GP1_RVALID          (BYolo_GP1_RVALID       ),
    .BYolo_GP1_WREADY          (BYolo_GP1_WREADY       ),
    .BYolo_GP1_BID             (BYolo_GP1_BID          ),
    .BYolo_GP1_RID             (BYolo_GP1_RID          ),
    .BYolo_GP1_BRESP           (BYolo_GP1_BRESP        ),
    .BYolo_GP1_RRESP           (BYolo_GP1_RRESP        ),
    .BYolo_GP1_RDATA           (BYolo_GP1_RDATA        ),
      
    .User_GP0_ARVALID          (User_GP0_ARVALID       ),
    .User_GP0_AWVALID          (User_GP0_AWVALID       ),
    .User_GP0_BREADY           (User_GP0_BREADY        ),
    .User_GP0_RREADY           (User_GP0_RREADY        ),
    .User_GP0_WLAST            (User_GP0_WLAST         ),
    .User_GP0_WVALID           (User_GP0_WVALID        ),
    .User_GP0_ARID             (User_GP0_ARID          ),
    .User_GP0_AWID             (User_GP0_AWID          ),
    .User_GP0_WID              (User_GP0_WID           ),
    .User_GP0_ARBURST          (User_GP0_ARBURST       ),
    .User_GP0_ARLOCK           (User_GP0_ARLOCK        ),
    .User_GP0_ARSIZE           (User_GP0_ARSIZE        ),
    .User_GP0_AWBURST          (User_GP0_AWBURST       ),
    .User_GP0_AWLOCK           (User_GP0_AWLOCK        ),
    .User_GP0_AWSIZE           (User_GP0_AWSIZE        ),
    .User_GP0_ARPROT           (User_GP0_ARPROT        ),
    .User_GP0_AWPROT           (User_GP0_AWPROT        ),
    .User_GP0_ARADDR           (User_GP0_ARADDR        ),
    .User_GP0_AWADDR           (User_GP0_AWADDR        ),
    .User_GP0_WDATA            (User_GP0_WDATA         ),
    .User_GP0_ARCACHE          (User_GP0_ARCACHE       ),
    .User_GP0_ARLEN            (User_GP0_ARLEN         ),
    .User_GP0_ARQOS            (User_GP0_ARQOS         ),
    .User_GP0_AWCACHE          (User_GP0_AWCACHE       ),
    .User_GP0_AWLEN            (User_GP0_AWLEN         ),
    .User_GP0_AWQOS            (User_GP0_AWQOS         ),
    .User_GP0_WSTRB            (User_GP0_WSTRB         ),
    .User_GP0_ARREADY          (User_GP0_ARREADY       ),
    .User_GP0_AWREADY          (User_GP0_AWREADY       ),
    .User_GP0_BVALID           (User_GP0_BVALID        ),
    .User_GP0_RLAST            (User_GP0_RLAST         ),
    .User_GP0_RVALID           (User_GP0_RVALID        ),
    .User_GP0_WREADY           (User_GP0_WREADY        ),
    .User_GP0_BID              (User_GP0_BID           ),
    .User_GP0_RID              (User_GP0_RID           ),
    .User_GP0_BRESP            (User_GP0_BRESP         ),
    .User_GP0_RRESP            (User_GP0_RRESP         ),
    .User_GP0_RDATA            (User_GP0_RDATA         ),
          
    .User_GP1_ARVALID          (User_GP1_ARVALID       ),
    .User_GP1_AWVALID          (User_GP1_AWVALID       ),
    .User_GP1_BREADY           (User_GP1_BREADY        ),
    .User_GP1_RREADY           (User_GP1_RREADY        ),
    .User_GP1_WLAST            (User_GP1_WLAST         ),
    .User_GP1_WVALID           (User_GP1_WVALID        ),
    .User_GP1_ARID             (User_GP1_ARID          ),
    .User_GP1_AWID             (User_GP1_AWID          ),
    .User_GP1_WID              (User_GP1_WID           ),
    .User_GP1_ARBURST          (User_GP1_ARBURST       ),
    .User_GP1_ARLOCK           (User_GP1_ARLOCK        ),
    .User_GP1_ARSIZE           (User_GP1_ARSIZE        ),
    .User_GP1_AWBURST          (User_GP1_AWBURST       ),
    .User_GP1_AWLOCK           (User_GP1_AWLOCK        ),
    .User_GP1_AWSIZE           (User_GP1_AWSIZE        ),
    .User_GP1_ARPROT           (User_GP1_ARPROT        ),
    .User_GP1_AWPROT           (User_GP1_AWPROT        ),
    .User_GP1_ARADDR           (User_GP1_ARADDR        ),
    .User_GP1_AWADDR           (User_GP1_AWADDR        ),
    .User_GP1_WDATA            (User_GP1_WDATA         ),
    .User_GP1_ARCACHE          (User_GP1_ARCACHE       ),
    .User_GP1_ARLEN            (User_GP1_ARLEN         ),
    .User_GP1_ARQOS            (User_GP1_ARQOS         ),
    .User_GP1_AWCACHE          (User_GP1_AWCACHE       ),
    .User_GP1_AWLEN            (User_GP1_AWLEN         ),
    .User_GP1_AWQOS            (User_GP1_AWQOS         ),
    .User_GP1_WSTRB            (User_GP1_WSTRB         ),
    .User_GP1_ARREADY          (User_GP1_ARREADY       ),
    .User_GP1_AWREADY          (User_GP1_AWREADY       ),
    .User_GP1_BVALID           (User_GP1_BVALID        ),
    .User_GP1_RLAST            (User_GP1_RLAST         ),
    .User_GP1_RVALID           (User_GP1_RVALID        ),
    .User_GP1_WREADY           (User_GP1_WREADY        ),
    .User_GP1_BID              (User_GP1_BID           ),
    .User_GP1_RID              (User_GP1_RID           ),
    .User_GP1_BRESP            (User_GP1_BRESP         ),
    .User_GP1_RRESP            (User_GP1_RRESP         ),
    .User_GP1_RDATA            (User_GP1_RDATA         ),  

    .S_AXI_HP0_ARADDR          (S0_AXI_HP_HC_ARADDR    ),
    .S_AXI_HP0_ARBURST         (S0_AXI_HP_HC_ARBURST   ),
    .S_AXI_HP0_ARCACHE         (S0_AXI_HP_HC_ARCACHE   ),
    .S_AXI_HP0_ARID            (S0_AXI_HP_HC_ARID      ),
    .S_AXI_HP0_ARLEN           (S0_AXI_HP_HC_ARLEN     ),
    .S_AXI_HP0_ARLOCK          (S0_AXI_HP_HC_ARLOCK    ),
    .S_AXI_HP0_ARPROT          (S0_AXI_HP_HC_ARPROT    ),
    .S_AXI_HP0_ARQOS           (S0_AXI_HP_HC_ARQOS     ),
    .S_AXI_HP0_ARREADY         (S0_AXI_HP_HC_ARREADY   ),
    .S_AXI_HP0_ARSIZE          (S0_AXI_HP_HC_ARSIZE    ),
    .S_AXI_HP0_ARVALID         (S0_AXI_HP_HC_ARVALID   ),
    .S_AXI_HP0_AWADDR          (S0_AXI_HP_HC_AWADDR    ),
    .S_AXI_HP0_AWBURST         (S0_AXI_HP_HC_AWBURST   ),
    .S_AXI_HP0_AWCACHE         (S0_AXI_HP_HC_AWCACHE   ),
    .S_AXI_HP0_AWID            (S0_AXI_HP_HC_AWID      ),
    .S_AXI_HP0_AWLEN           (S0_AXI_HP_HC_AWLEN     ),
    .S_AXI_HP0_AWLOCK          (S0_AXI_HP_HC_AWLOCK    ),
    .S_AXI_HP0_AWPROT          (S0_AXI_HP_HC_AWPROT    ),
    .S_AXI_HP0_AWQOS           (S0_AXI_HP_HC_AWQOS     ),
    .S_AXI_HP0_AWREADY         (S0_AXI_HP_HC_AWREADY   ),
    .S_AXI_HP0_AWSIZE          (S0_AXI_HP_HC_AWSIZE    ),
    .S_AXI_HP0_AWVALID         (S0_AXI_HP_HC_AWVALID   ),
    .S_AXI_HP0_BID             (S0_AXI_HP_HC_BID       ),
    .S_AXI_HP0_BREADY          (S0_AXI_HP_HC_BREADY    ),
    .S_AXI_HP0_BRESP           (S0_AXI_HP_HC_BRESP     ),
    .S_AXI_HP0_BVALID          (S0_AXI_HP_HC_BVALID    ),
    .S_AXI_HP0_RDATA           (S0_AXI_HP_HC_RDATA     ),
    .S_AXI_HP0_RID             (S0_AXI_HP_HC_RID       ),
    .S_AXI_HP0_RLAST           (S0_AXI_HP_HC_RLAST     ),
    .S_AXI_HP0_RREADY          (S0_AXI_HP_HC_RREADY    ),
    .S_AXI_HP0_RRESP           (S0_AXI_HP_HC_RRESP     ),
    .S_AXI_HP0_RVALID          (S0_AXI_HP_HC_RVALID    ),
    .S_AXI_HP0_WDATA           (S0_AXI_HP_HC_WDATA     ),
    .S_AXI_HP0_WID             (S0_AXI_HP_HC_WID       ),
    .S_AXI_HP0_WLAST           (S0_AXI_HP_HC_WLAST     ),
    .S_AXI_HP0_WREADY          (S0_AXI_HP_HC_WREADY    ),
    .S_AXI_HP0_WSTRB           (S0_AXI_HP_HC_WSTRB     ),
    .S_AXI_HP0_WVALID          (S0_AXI_HP_HC_WVALID    ),

    .S_AXI_HP0_RACOUNT         (                         ),
    .S_AXI_HP0_RCOUNT          (                         ),
    .S_AXI_HP0_RDISSUECAP1_EN  (S_AXI_HP0_RDISSUECAP1_EN ),
    .S_AXI_HP0_WACOUNT         (                         ),
    .S_AXI_HP0_WCOUNT          (                         ),
    .S_AXI_HP0_WRISSUECAP1_EN  (S_AXI_HP0_WRISSUECAP1_EN ),

    .S_AXI_HP1_ARADDR          (S1_AXI_HP_HC_ARADDR      ),
    .S_AXI_HP1_ARBURST         (S1_AXI_HP_HC_ARBURST     ),
    .S_AXI_HP1_ARCACHE         (S1_AXI_HP_HC_ARCACHE     ),
    .S_AXI_HP1_ARID            (S1_AXI_HP_HC_ARID        ),
    .S_AXI_HP1_ARLEN           (S1_AXI_HP_HC_ARLEN       ),
    .S_AXI_HP1_ARLOCK          (S1_AXI_HP_HC_ARLOCK      ),
    .S_AXI_HP1_ARPROT          (S1_AXI_HP_HC_ARPROT      ),
    .S_AXI_HP1_ARQOS           (S1_AXI_HP_HC_ARQOS       ),
    .S_AXI_HP1_ARREADY         (S1_AXI_HP_HC_ARREADY     ),
    .S_AXI_HP1_ARSIZE          (S1_AXI_HP_HC_ARSIZE      ),
    .S_AXI_HP1_ARVALID         (S1_AXI_HP_HC_ARVALID     ),
    .S_AXI_HP1_AWADDR          (S1_AXI_HP_HC_AWADDR      ),
    .S_AXI_HP1_AWBURST         (S1_AXI_HP_HC_AWBURST     ),
    .S_AXI_HP1_AWCACHE         (S1_AXI_HP_HC_AWCACHE     ),
    .S_AXI_HP1_AWID            (S1_AXI_HP_HC_AWID        ),
    .S_AXI_HP1_AWLEN           (S1_AXI_HP_HC_AWLEN       ),
    .S_AXI_HP1_AWLOCK          (S1_AXI_HP_HC_AWLOCK      ),
    .S_AXI_HP1_AWPROT          (S1_AXI_HP_HC_AWPROT      ),
    .S_AXI_HP1_AWQOS           (S1_AXI_HP_HC_AWQOS       ),
    .S_AXI_HP1_AWREADY         (S1_AXI_HP_HC_AWREADY     ),
    .S_AXI_HP1_AWSIZE          (S1_AXI_HP_HC_AWSIZE      ),
    .S_AXI_HP1_AWVALID         (S1_AXI_HP_HC_AWVALID     ),
    .S_AXI_HP1_BID             (S1_AXI_HP_HC_BID         ),
    .S_AXI_HP1_BREADY          (S1_AXI_HP_HC_BREADY      ),
    .S_AXI_HP1_BRESP           (S1_AXI_HP_HC_BRESP       ),
    .S_AXI_HP1_BVALID          (S1_AXI_HP_HC_BVALID      ),
    .S_AXI_HP1_RDATA           (S1_AXI_HP_HC_RDATA       ),
    .S_AXI_HP1_RID             (S1_AXI_HP_HC_RID         ),
    .S_AXI_HP1_RLAST           (S1_AXI_HP_HC_RLAST       ),
    .S_AXI_HP1_RREADY          (S1_AXI_HP_HC_RREADY      ),
    .S_AXI_HP1_RRESP           (S1_AXI_HP_HC_RRESP       ),
    .S_AXI_HP1_RVALID          (S1_AXI_HP_HC_RVALID      ),
    .S_AXI_HP1_WDATA           (S1_AXI_HP_HC_WDATA       ),
    .S_AXI_HP1_WID             (S1_AXI_HP_HC_WID         ),
    .S_AXI_HP1_WLAST           (S1_AXI_HP_HC_WLAST       ),
    .S_AXI_HP1_WREADY          (S1_AXI_HP_HC_WREADY      ),
    .S_AXI_HP1_WSTRB           (S1_AXI_HP_HC_WSTRB       ),
    .S_AXI_HP1_WVALID          (S1_AXI_HP_HC_WVALID      ),    
    .S_AXI_HP1_RACOUNT         (S_AXI_HP1_RACOUNT        ),
    .S_AXI_HP1_RCOUNT          (S_AXI_HP1_RCOUNT         ),
    .S_AXI_HP1_RDISSUECAP1_EN  (S_AXI_HP1_RDISSUECAP1_EN ),
    .S_AXI_HP1_WACOUNT         (S_AXI_HP1_WACOUNT        ),
    .S_AXI_HP1_WCOUNT          (S_AXI_HP1_WCOUNT         ),
    .S_AXI_HP1_WRISSUECAP1_EN  (S_AXI_HP1_WRISSUECAP1_EN ),    

    .S_AXI_HP2_ARADDR          (S2_AXI_HP_HC_ARADDR      ),
    .S_AXI_HP2_ARBURST         (S2_AXI_HP_HC_ARBURST     ),
    .S_AXI_HP2_ARCACHE         (S2_AXI_HP_HC_ARCACHE     ),
    .S_AXI_HP2_ARID            (S2_AXI_HP_HC_ARID        ),
    .S_AXI_HP2_ARLEN           (S2_AXI_HP_HC_ARLEN       ),
    .S_AXI_HP2_ARLOCK          (S2_AXI_HP_HC_ARLOCK      ),
    .S_AXI_HP2_ARPROT          (S2_AXI_HP_HC_ARPROT      ),
    .S_AXI_HP2_ARQOS           (S2_AXI_HP_HC_ARQOS       ),
    .S_AXI_HP2_ARREADY         (S2_AXI_HP_HC_ARREADY     ),
    .S_AXI_HP2_ARSIZE          (S2_AXI_HP_HC_ARSIZE      ),
    .S_AXI_HP2_ARVALID         (S2_AXI_HP_HC_ARVALID     ),
    .S_AXI_HP2_AWADDR          (S2_AXI_HP_HC_AWADDR      ),
    .S_AXI_HP2_AWBURST         (S2_AXI_HP_HC_AWBURST     ),
    .S_AXI_HP2_AWCACHE         (S2_AXI_HP_HC_AWCACHE     ),
    .S_AXI_HP2_AWID            (S2_AXI_HP_HC_AWID        ),
    .S_AXI_HP2_AWLEN           (S2_AXI_HP_HC_AWLEN       ),
    .S_AXI_HP2_AWLOCK          (S2_AXI_HP_HC_AWLOCK      ),
    .S_AXI_HP2_AWPROT          (S2_AXI_HP_HC_AWPROT      ),
    .S_AXI_HP2_AWQOS           (S2_AXI_HP_HC_AWQOS       ),
    .S_AXI_HP2_AWREADY         (S2_AXI_HP_HC_AWREADY     ),
    .S_AXI_HP2_AWSIZE          (S2_AXI_HP_HC_AWSIZE      ),
    .S_AXI_HP2_AWVALID         (S2_AXI_HP_HC_AWVALID     ),
    .S_AXI_HP2_BID             (S2_AXI_HP_HC_BID         ),
    .S_AXI_HP2_BREADY          (S2_AXI_HP_HC_BREADY      ),
    .S_AXI_HP2_BRESP           (S2_AXI_HP_HC_BRESP       ),
    .S_AXI_HP2_BVALID          (S2_AXI_HP_HC_BVALID      ),
    .S_AXI_HP2_RDATA           (S2_AXI_HP_HC_RDATA       ),
    .S_AXI_HP2_RID             (S2_AXI_HP_HC_RID         ),
    .S_AXI_HP2_RLAST           (S2_AXI_HP_HC_RLAST       ),
    .S_AXI_HP2_RREADY          (S2_AXI_HP_HC_RREADY      ),
    .S_AXI_HP2_RRESP           (S2_AXI_HP_HC_RRESP       ),
    .S_AXI_HP2_RVALID          (S2_AXI_HP_HC_RVALID      ),
    .S_AXI_HP2_WDATA           (S2_AXI_HP_HC_WDATA       ),
    .S_AXI_HP2_WID             (S2_AXI_HP_HC_WID         ),
    .S_AXI_HP2_WLAST           (S2_AXI_HP_HC_WLAST       ),
    .S_AXI_HP2_WREADY          (S2_AXI_HP_HC_WREADY      ),
    .S_AXI_HP2_WSTRB           (S2_AXI_HP_HC_WSTRB       ),
    .S_AXI_HP2_WVALID          (S2_AXI_HP_HC_WVALID      ), 
        
    .S_AXI_HP2_1_ARADDR        (S_AXI_HP2_ARADDR         ),
    .S_AXI_HP2_1_ARBURST       (S_AXI_HP2_ARBURST        ),
    .S_AXI_HP2_1_ARCACHE       (S_AXI_HP2_ARCACHE        ),
    .S_AXI_HP2_1_ARID          (S_AXI_HP2_ARID           ),
    .S_AXI_HP2_1_ARLEN         (S_AXI_HP2_ARLEN          ),
    .S_AXI_HP2_1_ARLOCK        (S_AXI_HP2_ARLOCK         ),
    .S_AXI_HP2_1_ARPROT        (S_AXI_HP2_ARPROT         ),
    .S_AXI_HP2_1_ARQOS         (S_AXI_HP2_ARQOS          ),
    .S_AXI_HP2_1_ARREADY       (S_AXI_HP2_ARREADY        ),
    .S_AXI_HP2_1_ARSIZE        (S_AXI_HP2_ARSIZE         ),
    .S_AXI_HP2_1_ARVALID       (S_AXI_HP2_ARVALID        ),
    .S_AXI_HP2_1_AWADDR        (S_AXI_HP2_AWADDR         ),
    .S_AXI_HP2_1_AWBURST       (S_AXI_HP2_AWBURST        ),
    .S_AXI_HP2_1_AWCACHE       (S_AXI_HP2_AWCACHE        ),
    .S_AXI_HP2_1_AWID          (S_AXI_HP2_AWID           ),
    .S_AXI_HP2_1_AWLEN         (S_AXI_HP2_AWLEN          ),
    .S_AXI_HP2_1_AWLOCK        (S_AXI_HP2_AWLOCK         ),
    .S_AXI_HP2_1_AWPROT        (S_AXI_HP2_AWPROT         ),
    .S_AXI_HP2_1_AWQOS         (S_AXI_HP2_AWQOS          ),
    .S_AXI_HP2_1_AWREADY       (S_AXI_HP2_AWREADY        ),
    .S_AXI_HP2_1_AWSIZE        (S_AXI_HP2_AWSIZE         ),
    .S_AXI_HP2_1_AWVALID       (S_AXI_HP2_AWVALID        ),
    .S_AXI_HP2_1_BID           (S_AXI_HP2_BID            ),
    .S_AXI_HP2_1_BREADY        (S_AXI_HP2_BREADY         ),
    .S_AXI_HP2_1_BRESP         (S_AXI_HP2_BRESP          ),
    .S_AXI_HP2_1_BVALID        (S_AXI_HP2_BVALID         ),
    .S_AXI_HP2_1_RDATA         (S_AXI_HP2_RDATA          ),
    .S_AXI_HP2_1_RID           (S_AXI_HP2_RID            ),
    .S_AXI_HP2_1_RLAST         (S_AXI_HP2_RLAST          ),
    .S_AXI_HP2_1_RREADY        (S_AXI_HP2_RREADY         ),
    .S_AXI_HP2_1_RRESP         (S_AXI_HP2_RRESP          ),
    .S_AXI_HP2_1_RVALID        (S_AXI_HP2_RVALID         ),
    .S_AXI_HP2_1_WDATA         (S_AXI_HP2_WDATA          ),
    .S_AXI_HP2_1_WID           (S_AXI_HP2_WID            ),
    .S_AXI_HP2_1_WLAST         (S_AXI_HP2_WLAST          ),
    .S_AXI_HP2_1_WREADY        (S_AXI_HP2_WREADY         ),
    .S_AXI_HP2_1_WSTRB         (S_AXI_HP2_WSTRB          ),
    .S_AXI_HP2_1_WVALID        (S_AXI_HP2_WVALID         ),

    .S_AXI_HP2_RACOUNT         (S_AXI_HP2_RACOUNT        ),
    .S_AXI_HP2_RCOUNT          (S_AXI_HP2_RCOUNT         ),
    .S_AXI_HP2_RDISSUECAP1_EN  (S_AXI_HP2_RDISSUECAP1_EN ),
    .S_AXI_HP2_WACOUNT         (S_AXI_HP2_WACOUNT        ),
    .S_AXI_HP2_WCOUNT          (S_AXI_HP2_WCOUNT         ),
    .S_AXI_HP2_WRISSUECAP1_EN  (S_AXI_HP2_WRISSUECAP1_EN ),    

    .S_AXI_HP3_ARADDR          (S3_AXI_HP_HC_ARADDR      ),
    .S_AXI_HP3_ARBURST         (S3_AXI_HP_HC_ARBURST     ),
    .S_AXI_HP3_ARCACHE         (S3_AXI_HP_HC_ARCACHE     ),
    .S_AXI_HP3_ARID            (S3_AXI_HP_HC_ARID        ),
    .S_AXI_HP3_ARLEN           (S3_AXI_HP_HC_ARLEN       ),
    .S_AXI_HP3_ARLOCK          (S3_AXI_HP_HC_ARLOCK      ),
    .S_AXI_HP3_ARPROT          (S3_AXI_HP_HC_ARPROT      ),
    .S_AXI_HP3_ARQOS           (S3_AXI_HP_HC_ARQOS       ),
    .S_AXI_HP3_ARREADY         (S3_AXI_HP_HC_ARREADY     ),
    .S_AXI_HP3_ARSIZE          (S3_AXI_HP_HC_ARSIZE      ),
    .S_AXI_HP3_ARVALID         (S3_AXI_HP_HC_ARVALID     ),
    .S_AXI_HP3_AWADDR          (S3_AXI_HP_HC_AWADDR      ),
    .S_AXI_HP3_AWBURST         (S3_AXI_HP_HC_AWBURST     ),
    .S_AXI_HP3_AWCACHE         (S3_AXI_HP_HC_AWCACHE     ),
    .S_AXI_HP3_AWID            (S3_AXI_HP_HC_AWID        ),
    .S_AXI_HP3_AWLEN           (S3_AXI_HP_HC_AWLEN       ),
    .S_AXI_HP3_AWLOCK          (S3_AXI_HP_HC_AWLOCK      ),
    .S_AXI_HP3_AWPROT          (S3_AXI_HP_HC_AWPROT      ),
    .S_AXI_HP3_AWQOS           (S3_AXI_HP_HC_AWQOS       ),
    .S_AXI_HP3_AWREADY         (S3_AXI_HP_HC_AWREADY     ),
    .S_AXI_HP3_AWSIZE          (S3_AXI_HP_HC_AWSIZE      ),
    .S_AXI_HP3_AWVALID         (S3_AXI_HP_HC_AWVALID     ),
    .S_AXI_HP3_BID             (S3_AXI_HP_HC_BID         ),
    .S_AXI_HP3_BREADY          (S3_AXI_HP_HC_BREADY      ),
    .S_AXI_HP3_BRESP           (S3_AXI_HP_HC_BRESP       ),
    .S_AXI_HP3_BVALID          (S3_AXI_HP_HC_BVALID      ),
    .S_AXI_HP3_RDATA           (S3_AXI_HP_HC_RDATA       ),
    .S_AXI_HP3_RID             (S3_AXI_HP_HC_RID         ),
    .S_AXI_HP3_RLAST           (S3_AXI_HP_HC_RLAST       ),
    .S_AXI_HP3_RREADY          (S3_AXI_HP_HC_RREADY      ),
    .S_AXI_HP3_RRESP           (S3_AXI_HP_HC_RRESP       ),
    .S_AXI_HP3_RVALID          (S3_AXI_HP_HC_RVALID      ),
    .S_AXI_HP3_WDATA           (S3_AXI_HP_HC_WDATA       ),
    .S_AXI_HP3_WID             (S3_AXI_HP_HC_WID         ),
    .S_AXI_HP3_WLAST           (S3_AXI_HP_HC_WLAST       ),
    .S_AXI_HP3_WREADY          (S3_AXI_HP_HC_WREADY      ),
    .S_AXI_HP3_WSTRB           (S3_AXI_HP_HC_WSTRB       ),
    .S_AXI_HP3_WVALID          (S3_AXI_HP_HC_WVALID      ),      
    .S_AXI_HP3_RACOUNT         (S_AXI_HP3_RACOUNT        ),
    .S_AXI_HP3_RCOUNT          (S_AXI_HP3_RCOUNT         ),
    .S_AXI_HP3_RDISSUECAP1_EN  (S_AXI_HP3_RDISSUECAP1_EN ),
    .S_AXI_HP3_WACOUNT         (S_AXI_HP3_WACOUNT        ),
    .S_AXI_HP3_WCOUNT          (S_AXI_HP3_WCOUNT         ),
    .S_AXI_HP3_WRISSUECAP1_EN  (S_AXI_HP3_WRISSUECAP1_EN ),    

    .pl_araddr                 (pl_araddr                ),
    .pl_arinfo                 (pl_arinfo                ),
    .pl_arlast                 (pl_arlast                ),
    .pl_arready                (pl_arready               ),
    .pl_arvalid                (pl_arvalid               ),
    .pl_awaddr                 (pl_awaddr                ),
    .pl_awdata                 (pl_awdata                ),
    .pl_awen                   (pl_awen                  ),
    .pl_awinfo                 (pl_awinfo                ),
    .pl_awlast                 (pl_awlast                ),
    .pl_awready                (pl_awready               ),
    .pl_awvalid                (pl_awvalid               ),
    .pl_bvalid                 (pl_bvalid                ),  
    .pl_bready                 (pl_bready                ),  
    .pl_bist_clk               (pl_bist_clk              ),
    .pl_bist_rstn              (pl_bist_rstn             ),
    .pl_bist_en                (pl_bist_en               ),      
    .pl_bist_done              (pl_bist_done             ),
    .pl_bist_err               (pl_bist_err              ),
    .pl_bist_err_inv           (pl_bist_err_inv          ),
    .pl_clk_div_out            (pl_clk_div_out           ),
    .pl_clk_en_b               (pl_clk_en_b              ),
    .pl_int_info               (pl_int_info              ),   
    .pl_int_valid              (pl_int_valid             ), 
    .pl_int_ready              (pl_int_ready             ),      
    .pl_itf_clk                (pl_itf_clk               ),
    .pl_ra_araddr              (pl_ra_araddr             ),
    .pl_ra_arready             (pl_ra_arready            ),
    .pl_ra_arvalid             (pl_ra_arvalid            ),
    .pl_ra_awaddr              (pl_ra_awaddr             ),
    .pl_ra_awdata              (pl_ra_awdata             ),
    .pl_ra_awready             (pl_ra_awready            ),
    .pl_ra_awvalid             (pl_ra_awvalid            ),
    .pl_ra_clk                 (pl_ra_clk                ),
    .pl_ra_rdata               (pl_ra_rdata              ),
    .pl_ra_rready              (pl_ra_rready             ),
    .pl_ra_rvalid              (pl_ra_rvalid             ),
    .pl_rdata                  (pl_rdata                 ),
    .pl_repair_done            (pl_repair_done           ),
    .pl_repair_fail            (pl_repair_fail           ),
    .pl_rlast                  (pl_rlast                 ),
    .pl_rready                 (pl_rready                ),
    .pl_rst_n                  (pl_rst_n                 ), 
    .pl_rvalid                 (pl_rvalid                ),
    .pl_scan_clk               (pl_scan_clk              ),
    .pl_scan_en                (pl_scan_en               ),
    .pl_scan_i                 (pl_scan_i[63:0]          ),
    .pl_scan_mode_b            (pl_scan_mode_b           ),
    .pl_scan_o                 (pl_scan_o                ),
    .pl_scan_rst_n             (pl_scan_rst_n            ),
  
    .test_irq                  (test_irq                 ),
    .customop_irq              (customop_irq             ),
    .ai_irq                    (ai_irq                   ),
    .clk_200mhz                (clk_200mhz               ),

    // WCIS-PL-ETH A2 begin
    .RGMII_0_txc                        (RGMII_0_txc                        ),
    .RGMII_0_tx_ctl                     (RGMII_0_tx_ctl                     ),
    .RGMII_0_td                         (RGMII_0_td                         ),
    .RGMII_0_rxc                        (RGMII_0_rxc                        ),
    .RGMII_0_rx_ctl                     (RGMII_0_rx_ctl                     ),
    .RGMII_0_rd                         (RGMII_0_rd                         ),
    .MDIO_PHY_0_mdc                     (MDIO_PHY_0_mdc                     ),
    .MDIO_PHY_0_mdio_io                 (MDIO_PHY_0_mdio_io                 ),
    .phy_reset_n                        (phy_reset_n                        )
    // WCIS-PL-ETH A2 end
    );

`ifdef WITH_NPU

// --------------------------------------------------------------------------
// NPU present (original vendor configuration).
// --------------------------------------------------------------------------
AI_Mate ZGolo(
  .hp_clk                   (ddr_clk                  ),
  .ui_clk                   (ddr_clk                  ),
  .reg_clk                  (gp_clk                   ),
  .sys_rst_n                (sys_rst_n & (~soft_rst)  & FCLK_RESET0_N ),
  .img_ready_0              (img_ready1               ),
  .img_data_0               ({40'b0,img_data1}        ),
  .img_valid_0              (img_valid1               ),
  .img_start_0              (img_start1               ),
 
  .app_addr                 (app_addr                 ),
  .app_cmd                  (app_cmd                  ),
  .app_en                   (app_en                   ),
  .app_wdf_data             (app_wdf_data             ),
  .app_wdf_end              (app_wdf_end              ),
  .app_wdf_mask             (app_wdf_mask             ),
  .app_wdf_wren             (app_wdf_wren             ),
  .app_rd_data              (app_rd_data              ),
  .app_rd_data_end          (app_rd_data_end          ),
  .app_rd_data_valid        (app_rd_data_valid        ),
  .app_rdy                  (app_rdy                  ),
  .app_wdf_rdy              (app_wdf_rdy              ),
  .ddr3_init_done           (ddr3_init_done           ),
  
  .M_AXI_GP0_ARVALID        (BYolo_GP0_ARVALID        ),
  .M_AXI_GP0_AWVALID        (BYolo_GP0_AWVALID        ),
  .M_AXI_GP0_BREADY         (BYolo_GP0_BREADY         ),
  .M_AXI_GP0_RREADY         (BYolo_GP0_RREADY         ),
  .M_AXI_GP0_WLAST          (BYolo_GP0_WLAST          ),
  .M_AXI_GP0_WVALID         (BYolo_GP0_WVALID         ),
  .M_AXI_GP0_ARID           (BYolo_GP0_ARID           ),
  .M_AXI_GP0_AWID           (BYolo_GP0_AWID           ),
  .M_AXI_GP0_WID            (BYolo_GP0_WID            ),
  .M_AXI_GP0_ARBURST        (BYolo_GP0_ARBURST        ),
  .M_AXI_GP0_ARLOCK         (BYolo_GP0_ARLOCK         ),
  .M_AXI_GP0_ARSIZE         (BYolo_GP0_ARSIZE         ),
  .M_AXI_GP0_AWBURST        (BYolo_GP0_AWBURST        ),
  .M_AXI_GP0_AWLOCK         (BYolo_GP0_AWLOCK         ),
  .M_AXI_GP0_AWSIZE         (BYolo_GP0_AWSIZE         ),
  .M_AXI_GP0_ARPROT         (BYolo_GP0_ARPROT         ),
  .M_AXI_GP0_AWPROT         (BYolo_GP0_AWPROT         ),
  .M_AXI_GP0_ARADDR         (BYolo_GP0_ARADDR         ),
  .M_AXI_GP0_AWADDR         (BYolo_GP0_AWADDR         ),
  .M_AXI_GP0_WDATA          (BYolo_GP0_WDATA          ),
  .M_AXI_GP0_ARCACHE        (BYolo_GP0_ARCACHE        ),
  .M_AXI_GP0_ARLEN          (BYolo_GP0_ARLEN          ),
  .M_AXI_GP0_ARQOS          (BYolo_GP0_ARQOS          ),
  .M_AXI_GP0_AWCACHE        (BYolo_GP0_AWCACHE        ),
  .M_AXI_GP0_AWLEN          (BYolo_GP0_AWLEN          ),
  .M_AXI_GP0_AWQOS          (BYolo_GP0_AWQOS          ),
  .M_AXI_GP0_WSTRB          (BYolo_GP0_WSTRB          ),
  .M_AXI_GP0_ARREADY        (BYolo_GP0_ARREADY        ),
  .M_AXI_GP0_AWREADY        (BYolo_GP0_AWREADY        ),
  .M_AXI_GP0_BVALID         (BYolo_GP0_BVALID         ),
  .M_AXI_GP0_RLAST          (BYolo_GP0_RLAST          ),
  .M_AXI_GP0_RVALID         (BYolo_GP0_RVALID         ),
  .M_AXI_GP0_WREADY         (BYolo_GP0_WREADY         ),
  .M_AXI_GP0_BID            (BYolo_GP0_BID            ),
  .M_AXI_GP0_RID            (BYolo_GP0_RID            ),
  .M_AXI_GP0_BRESP          (BYolo_GP0_BRESP          ),
  .M_AXI_GP0_RRESP          (BYolo_GP0_RRESP          ),
  .M_AXI_GP0_RDATA          (BYolo_GP0_RDATA          ),
  
  .M_AXI_GP1_ARVALID        (BYolo_GP1_ARVALID        ),
  .M_AXI_GP1_AWVALID        (BYolo_GP1_AWVALID        ),
  .M_AXI_GP1_BREADY         (BYolo_GP1_BREADY         ),
  .M_AXI_GP1_RREADY         (BYolo_GP1_RREADY         ),
  .M_AXI_GP1_WLAST          (BYolo_GP1_WLAST          ),
  .M_AXI_GP1_WVALID         (BYolo_GP1_WVALID         ),
  .M_AXI_GP1_ARID           (BYolo_GP1_ARID           ),
  .M_AXI_GP1_AWID           (BYolo_GP1_AWID           ),
  .M_AXI_GP1_WID            (BYolo_GP1_WID            ),
  .M_AXI_GP1_ARBURST        (BYolo_GP1_ARBURST        ),
  .M_AXI_GP1_ARLOCK         (BYolo_GP1_ARLOCK         ),
  .M_AXI_GP1_ARSIZE         (BYolo_GP1_ARSIZE         ),
  .M_AXI_GP1_AWBURST        (BYolo_GP1_AWBURST        ),
  .M_AXI_GP1_AWLOCK         (BYolo_GP1_AWLOCK         ),
  .M_AXI_GP1_AWSIZE         (BYolo_GP1_AWSIZE         ),
  .M_AXI_GP1_ARPROT         (BYolo_GP1_ARPROT         ),
  .M_AXI_GP1_AWPROT         (BYolo_GP1_AWPROT         ),
  .M_AXI_GP1_ARADDR         (BYolo_GP1_ARADDR         ),
  .M_AXI_GP1_AWADDR         (BYolo_GP1_AWADDR         ),
  .M_AXI_GP1_WDATA          (BYolo_GP1_WDATA          ),
  .M_AXI_GP1_ARCACHE        (BYolo_GP1_ARCACHE        ),
  .M_AXI_GP1_ARLEN          (BYolo_GP1_ARLEN          ),
  .M_AXI_GP1_ARQOS          (BYolo_GP1_ARQOS          ),
  .M_AXI_GP1_AWCACHE        (BYolo_GP1_AWCACHE        ),
  .M_AXI_GP1_AWLEN          (BYolo_GP1_AWLEN          ),
  .M_AXI_GP1_AWQOS          (BYolo_GP1_AWQOS          ),
  .M_AXI_GP1_WSTRB          (BYolo_GP1_WSTRB          ),
  .M_AXI_GP1_ARREADY        (BYolo_GP1_ARREADY        ),
  .M_AXI_GP1_AWREADY        (BYolo_GP1_AWREADY        ),
  .M_AXI_GP1_BVALID         (BYolo_GP1_BVALID         ),
  .M_AXI_GP1_RLAST          (BYolo_GP1_RLAST          ),
  .M_AXI_GP1_RVALID         (BYolo_GP1_RVALID         ),
  .M_AXI_GP1_WREADY         (BYolo_GP1_WREADY         ),
  .M_AXI_GP1_BID            (BYolo_GP1_BID            ),
  .M_AXI_GP1_RID            (BYolo_GP1_RID            ),
  .M_AXI_GP1_BRESP          (BYolo_GP1_BRESP          ),
  .M_AXI_GP1_RRESP          (BYolo_GP1_RRESP          ),
  .M_AXI_GP1_RDATA          (BYolo_GP1_RDATA          ),

  .S0_AXI_HP_HC_ARREADY     (S0_AXI_HP_HC_ARREADY     ),
  .S0_AXI_HP_HC_AWREADY     (S0_AXI_HP_HC_AWREADY     ),
  .S0_AXI_HP_HC_BVALID      (S0_AXI_HP_HC_BVALID      ),
  .S0_AXI_HP_HC_RLAST       (S0_AXI_HP_HC_RLAST       ),
  .S0_AXI_HP_HC_RVALID      (S0_AXI_HP_HC_RVALID      ),
  .S0_AXI_HP_HC_WREADY      (S0_AXI_HP_HC_WREADY      ),
  .S0_AXI_HP_HC_BRESP       (S0_AXI_HP_HC_BRESP       ),
  .S0_AXI_HP_HC_RRESP       (S0_AXI_HP_HC_RRESP       ),
  .S0_AXI_HP_HC_BID         (S0_AXI_HP_HC_BID         ),
  .S0_AXI_HP_HC_RID         (S0_AXI_HP_HC_RID         ),
  .S0_AXI_HP_HC_RDATA       (S0_AXI_HP_HC_RDATA       ),
  .S0_AXI_HP_HC_ARVALID     (S0_AXI_HP_HC_ARVALID     ),
  .S0_AXI_HP_HC_AWVALID     (S0_AXI_HP_HC_AWVALID     ),
  .S0_AXI_HP_HC_BREADY      (S0_AXI_HP_HC_BREADY      ),
  .S0_AXI_HP_HC_RREADY      (S0_AXI_HP_HC_RREADY      ),
  .S0_AXI_HP_HC_WLAST       (S0_AXI_HP_HC_WLAST       ),
  .S0_AXI_HP_HC_WVALID      (S0_AXI_HP_HC_WVALID      ),
  .S0_AXI_HP_HC_ARBURST     (S0_AXI_HP_HC_ARBURST     ),
  .S0_AXI_HP_HC_ARLOCK      (S0_AXI_HP_HC_ARLOCK      ),
  .S0_AXI_HP_HC_ARSIZE      (S0_AXI_HP_HC_ARSIZE      ),
  .S0_AXI_HP_HC_AWBURST     (S0_AXI_HP_HC_AWBURST     ),
  .S0_AXI_HP_HC_AWLOCK      (S0_AXI_HP_HC_AWLOCK      ),
  .S0_AXI_HP_HC_AWSIZE      (S0_AXI_HP_HC_AWSIZE      ),
  .S0_AXI_HP_HC_ARPROT      (S0_AXI_HP_HC_ARPROT      ),
  .S0_AXI_HP_HC_AWPROT      (S0_AXI_HP_HC_AWPROT      ),
  .S0_AXI_HP_HC_ARADDR      (S0_AXI_HP_HC_ARADDR      ),
  .S0_AXI_HP_HC_AWADDR      (S0_AXI_HP_HC_AWADDR      ),
  .S0_AXI_HP_HC_ARCACHE     (S0_AXI_HP_HC_ARCACHE     ),
  .S0_AXI_HP_HC_ARLEN       (S0_AXI_HP_HC_ARLEN       ),
  .S0_AXI_HP_HC_ARQOS       (S0_AXI_HP_HC_ARQOS       ),
  .S0_AXI_HP_HC_AWCACHE     (S0_AXI_HP_HC_AWCACHE     ),
  .S0_AXI_HP_HC_AWLEN       (S0_AXI_HP_HC_AWLEN       ),
  .S0_AXI_HP_HC_AWQOS       (S0_AXI_HP_HC_AWQOS       ),
  .S0_AXI_HP_HC_ARID        (S0_AXI_HP_HC_ARID        ),
  .S0_AXI_HP_HC_AWID        (S0_AXI_HP_HC_AWID        ),
  .S0_AXI_HP_HC_WID         (S0_AXI_HP_HC_WID         ),
  .S0_AXI_HP_HC_WDATA       (S0_AXI_HP_HC_WDATA       ),
  .S0_AXI_HP_HC_WSTRB       (S0_AXI_HP_HC_WSTRB       ), 

  .S1_AXI_HP_HC_ARREADY     (S1_AXI_HP_HC_ARREADY     ),
  .S1_AXI_HP_HC_AWREADY     (S1_AXI_HP_HC_AWREADY     ),
  .S1_AXI_HP_HC_BVALID      (S1_AXI_HP_HC_BVALID      ),
  .S1_AXI_HP_HC_RLAST       (S1_AXI_HP_HC_RLAST       ),
  .S1_AXI_HP_HC_RVALID      (S1_AXI_HP_HC_RVALID      ),
  .S1_AXI_HP_HC_WREADY      (S1_AXI_HP_HC_WREADY      ),
  .S1_AXI_HP_HC_BRESP       (S1_AXI_HP_HC_BRESP       ),
  .S1_AXI_HP_HC_RRESP       (S1_AXI_HP_HC_RRESP       ),
  .S1_AXI_HP_HC_BID         (S1_AXI_HP_HC_BID         ),
  .S1_AXI_HP_HC_RID         (S1_AXI_HP_HC_RID         ),
  .S1_AXI_HP_HC_RDATA       (S1_AXI_HP_HC_RDATA       ),
  .S1_AXI_HP_HC_ARVALID     (S1_AXI_HP_HC_ARVALID     ),
  .S1_AXI_HP_HC_AWVALID     (S1_AXI_HP_HC_AWVALID     ),
  .S1_AXI_HP_HC_BREADY      (S1_AXI_HP_HC_BREADY      ),
  .S1_AXI_HP_HC_RREADY      (S1_AXI_HP_HC_RREADY      ),
  .S1_AXI_HP_HC_WLAST       (S1_AXI_HP_HC_WLAST       ),
  .S1_AXI_HP_HC_WVALID      (S1_AXI_HP_HC_WVALID      ),
  .S1_AXI_HP_HC_ARBURST     (S1_AXI_HP_HC_ARBURST     ),
  .S1_AXI_HP_HC_ARLOCK      (S1_AXI_HP_HC_ARLOCK      ),
  .S1_AXI_HP_HC_ARSIZE      (S1_AXI_HP_HC_ARSIZE      ),
  .S1_AXI_HP_HC_AWBURST     (S1_AXI_HP_HC_AWBURST     ),
  .S1_AXI_HP_HC_AWLOCK      (S1_AXI_HP_HC_AWLOCK      ),
  .S1_AXI_HP_HC_AWSIZE      (S1_AXI_HP_HC_AWSIZE      ),
  .S1_AXI_HP_HC_ARPROT      (S1_AXI_HP_HC_ARPROT      ),
  .S1_AXI_HP_HC_AWPROT      (S1_AXI_HP_HC_AWPROT      ),
  .S1_AXI_HP_HC_ARADDR      (S1_AXI_HP_HC_ARADDR      ),
  .S1_AXI_HP_HC_AWADDR      (S1_AXI_HP_HC_AWADDR      ),
  .S1_AXI_HP_HC_ARCACHE     (S1_AXI_HP_HC_ARCACHE     ),
  .S1_AXI_HP_HC_ARLEN       (S1_AXI_HP_HC_ARLEN       ),
  .S1_AXI_HP_HC_ARQOS       (S1_AXI_HP_HC_ARQOS       ),
  .S1_AXI_HP_HC_AWCACHE     (S1_AXI_HP_HC_AWCACHE     ),
  .S1_AXI_HP_HC_AWLEN       (S1_AXI_HP_HC_AWLEN       ),
  .S1_AXI_HP_HC_AWQOS       (S1_AXI_HP_HC_AWQOS       ),
  .S1_AXI_HP_HC_ARID        (S1_AXI_HP_HC_ARID        ),
  .S1_AXI_HP_HC_AWID        (S1_AXI_HP_HC_AWID        ),
  .S1_AXI_HP_HC_WID         (S1_AXI_HP_HC_WID         ),
  .S1_AXI_HP_HC_WDATA       (S1_AXI_HP_HC_WDATA       ),
  .S1_AXI_HP_HC_WSTRB       (S1_AXI_HP_HC_WSTRB       ), 

  .S2_AXI_HP_HC_ARREADY     (S2_AXI_HP_HC_ARREADY     ),
  .S2_AXI_HP_HC_AWREADY     (S2_AXI_HP_HC_AWREADY     ),
  .S2_AXI_HP_HC_BVALID      (S2_AXI_HP_HC_BVALID      ),
  .S2_AXI_HP_HC_RLAST       (S2_AXI_HP_HC_RLAST       ),
  .S2_AXI_HP_HC_RVALID      (S2_AXI_HP_HC_RVALID      ),
  .S2_AXI_HP_HC_WREADY      (S2_AXI_HP_HC_WREADY      ),
  .S2_AXI_HP_HC_BRESP       (S2_AXI_HP_HC_BRESP       ),
  .S2_AXI_HP_HC_RRESP       (S2_AXI_HP_HC_RRESP       ),
  .S2_AXI_HP_HC_BID         (S2_AXI_HP_HC_BID         ),
  .S2_AXI_HP_HC_RID         (S2_AXI_HP_HC_RID         ),
  .S2_AXI_HP_HC_RDATA       (S2_AXI_HP_HC_RDATA       ),
  .S2_AXI_HP_HC_ARVALID     (S2_AXI_HP_HC_ARVALID     ),
  .S2_AXI_HP_HC_AWVALID     (S2_AXI_HP_HC_AWVALID     ),
  .S2_AXI_HP_HC_BREADY      (S2_AXI_HP_HC_BREADY      ),
  .S2_AXI_HP_HC_RREADY      (S2_AXI_HP_HC_RREADY      ),
  .S2_AXI_HP_HC_WLAST       (S2_AXI_HP_HC_WLAST       ),
  .S2_AXI_HP_HC_WVALID      (S2_AXI_HP_HC_WVALID      ),
  .S2_AXI_HP_HC_ARBURST     (S2_AXI_HP_HC_ARBURST     ),
  .S2_AXI_HP_HC_ARLOCK      (S2_AXI_HP_HC_ARLOCK      ),
  .S2_AXI_HP_HC_ARSIZE      (S2_AXI_HP_HC_ARSIZE      ),
  .S2_AXI_HP_HC_AWBURST     (S2_AXI_HP_HC_AWBURST     ),
  .S2_AXI_HP_HC_AWLOCK      (S2_AXI_HP_HC_AWLOCK      ),
  .S2_AXI_HP_HC_AWSIZE      (S2_AXI_HP_HC_AWSIZE      ),
  .S2_AXI_HP_HC_ARPROT      (S2_AXI_HP_HC_ARPROT      ),
  .S2_AXI_HP_HC_AWPROT      (S2_AXI_HP_HC_AWPROT      ),
  .S2_AXI_HP_HC_ARADDR      (S2_AXI_HP_HC_ARADDR      ),
  .S2_AXI_HP_HC_AWADDR      (S2_AXI_HP_HC_AWADDR      ),
  .S2_AXI_HP_HC_ARCACHE     (S2_AXI_HP_HC_ARCACHE     ),
  .S2_AXI_HP_HC_ARLEN       (S2_AXI_HP_HC_ARLEN       ),
  .S2_AXI_HP_HC_ARQOS       (S2_AXI_HP_HC_ARQOS       ),
  .S2_AXI_HP_HC_AWCACHE     (S2_AXI_HP_HC_AWCACHE     ),
  .S2_AXI_HP_HC_AWLEN       (S2_AXI_HP_HC_AWLEN       ),
  .S2_AXI_HP_HC_AWQOS       (S2_AXI_HP_HC_AWQOS       ),
  .S2_AXI_HP_HC_ARID        (S2_AXI_HP_HC_ARID        ),
  .S2_AXI_HP_HC_AWID        (S2_AXI_HP_HC_AWID        ),
  .S2_AXI_HP_HC_WID         (S2_AXI_HP_HC_WID         ),
  .S2_AXI_HP_HC_WDATA       (S2_AXI_HP_HC_WDATA       ),
  .S2_AXI_HP_HC_WSTRB       (S2_AXI_HP_HC_WSTRB       ), 

  .S3_AXI_HP_HC_ARREADY     (S3_AXI_HP_HC_ARREADY     ),
  .S3_AXI_HP_HC_AWREADY     (S3_AXI_HP_HC_AWREADY     ),
  .S3_AXI_HP_HC_BVALID      (S3_AXI_HP_HC_BVALID      ),
  .S3_AXI_HP_HC_RLAST       (S3_AXI_HP_HC_RLAST       ),
  .S3_AXI_HP_HC_RVALID      (S3_AXI_HP_HC_RVALID      ),
  .S3_AXI_HP_HC_WREADY      (S3_AXI_HP_HC_WREADY      ),
  .S3_AXI_HP_HC_BRESP       (S3_AXI_HP_HC_BRESP       ),
  .S3_AXI_HP_HC_RRESP       (S3_AXI_HP_HC_RRESP       ),
  .S3_AXI_HP_HC_BID         (S3_AXI_HP_HC_BID         ),
  .S3_AXI_HP_HC_RID         (S3_AXI_HP_HC_RID         ),
  .S3_AXI_HP_HC_RDATA       (S3_AXI_HP_HC_RDATA       ),
  .S3_AXI_HP_HC_ARVALID     (S3_AXI_HP_HC_ARVALID     ),
  .S3_AXI_HP_HC_AWVALID     (S3_AXI_HP_HC_AWVALID     ),
  .S3_AXI_HP_HC_BREADY      (S3_AXI_HP_HC_BREADY      ),
  .S3_AXI_HP_HC_RREADY      (S3_AXI_HP_HC_RREADY      ),
  .S3_AXI_HP_HC_WLAST       (S3_AXI_HP_HC_WLAST       ),
  .S3_AXI_HP_HC_WVALID      (S3_AXI_HP_HC_WVALID      ),
  .S3_AXI_HP_HC_ARBURST     (S3_AXI_HP_HC_ARBURST     ),
  .S3_AXI_HP_HC_ARLOCK      (S3_AXI_HP_HC_ARLOCK      ),
  .S3_AXI_HP_HC_ARSIZE      (S3_AXI_HP_HC_ARSIZE      ),
  .S3_AXI_HP_HC_AWBURST     (S3_AXI_HP_HC_AWBURST     ),
  .S3_AXI_HP_HC_AWLOCK      (S3_AXI_HP_HC_AWLOCK      ),
  .S3_AXI_HP_HC_AWSIZE      (S3_AXI_HP_HC_AWSIZE      ),
  .S3_AXI_HP_HC_ARPROT      (S3_AXI_HP_HC_ARPROT      ),
  .S3_AXI_HP_HC_AWPROT      (S3_AXI_HP_HC_AWPROT      ),
  .S3_AXI_HP_HC_ARADDR      (S3_AXI_HP_HC_ARADDR      ),
  .S3_AXI_HP_HC_AWADDR      (S3_AXI_HP_HC_AWADDR      ),
  .S3_AXI_HP_HC_ARCACHE     (S3_AXI_HP_HC_ARCACHE     ),
  .S3_AXI_HP_HC_ARLEN       (S3_AXI_HP_HC_ARLEN       ),
  .S3_AXI_HP_HC_ARQOS       (S3_AXI_HP_HC_ARQOS       ),
  .S3_AXI_HP_HC_AWCACHE     (S3_AXI_HP_HC_AWCACHE     ),
  .S3_AXI_HP_HC_AWLEN       (S3_AXI_HP_HC_AWLEN       ),
  .S3_AXI_HP_HC_AWQOS       (S3_AXI_HP_HC_AWQOS       ),
  .S3_AXI_HP_HC_ARID        (S3_AXI_HP_HC_ARID        ),
  .S3_AXI_HP_HC_AWID        (S3_AXI_HP_HC_AWID        ),
  .S3_AXI_HP_HC_WID         (S3_AXI_HP_HC_WID         ),
  .S3_AXI_HP_HC_WDATA       (S3_AXI_HP_HC_WDATA       ),
  .S3_AXI_HP_HC_WSTRB       (S3_AXI_HP_HC_WSTRB       ), 

  .pl_awaddr                (pl_awaddr                ),
  .pl_awdata                (pl_awdata                ),
  .pl_awen                  (pl_awen                  ),
  .pl_awinfo                (pl_awinfo                ),
  .pl_awlast                (pl_awlast                ),
  .pl_awvalid               (pl_awvalid               ),
  .pl_awready               (pl_awready               ),
  .pl_araddr                (pl_araddr                ),
  .pl_arinfo                (pl_arinfo                ),
  .pl_arlast                (pl_arlast                ),
  .pl_arvalid               (pl_arvalid               ),
  .pl_arready               (pl_arready               ),
  .pl_rdata                 (pl_rdata                 ),
  .pl_rvalid                (pl_rvalid                ),
  .pl_rlast                 (pl_rlast                 ),
  .pl_rready                (pl_rready                ),
  .pl_bvalid                (pl_bvalid                ),  //30TAI
  .pl_bready                (pl_bready                ),  //30TAI  
  .pl_ra_awaddr             (pl_ra_awaddr             ),
  .pl_ra_awdata             (pl_ra_awdata             ),
  .pl_ra_awvalid            (pl_ra_awvalid            ),
  .pl_ra_awready            (pl_ra_awready            ),
  .pl_ra_araddr             (pl_ra_araddr             ),
  .pl_ra_arvalid            (pl_ra_arvalid            ),
  .pl_ra_arready            (pl_ra_arready            ),
  .pl_ra_rdata              (pl_ra_rdata              ),
  .pl_ra_rvalid             (pl_ra_rvalid             ),
  .pl_ra_rready             (pl_ra_rready             ),
  .pl_int_info              (pl_int_info              ),  //30TAI  
  .pl_int_valid             (pl_int_valid             ),  //30TAI
  .pl_int_ready             (pl_int_ready             ),  //30TAI  
  .pl_ra_clk                (pl_ra_clk                ),
  .pl_itf_clk               (pl_itf_clk               ),
  .pl_rst_n                 (pl_rst_n                 ),
  .pl_clk_en_b              (pl_clk_en_b              ),
  .pl_bist_clk              (pl_bist_clk              ),
  .pl_bist_rstn             (pl_bist_rstn             ),
  .pl_bist_en               (pl_bist_en               ),
  .pl_bist_err              (pl_bist_err              ),
  .pl_bist_done             (pl_bist_done             ),
  .pl_repair_done           (pl_repair_done           ),
  .pl_repair_fail           (pl_repair_fail           ),
  .pl_bist_err_inv          (pl_bist_err_inv          ),
  .pl_clk_div_out           (pl_clk_div_out           ),
  .pl_scan_mode_b           (pl_scan_mode_b           ),
  .pl_scan_en               (pl_scan_en               ),
  .pl_scan_clk              (pl_scan_clk              ),
  .pl_scan_rst_n            (pl_scan_rst_n            ),
  .pl_scan_i                (pl_scan_i                ),
  .pl_scan_o                (pl_scan_o                ),

  //UserCustomOp_0 BUS
  .UserCustomOp_0_awwaddr   ( User_Ddr_awwaddr  ),
  .UserCustomOp_0_awwdata   ( User_Ddr_awwdata  ),
  .UserCustomOp_0_awwinfo   ( User_Ddr_awwinfo  ), //{1'b0,pl_awen[63:0],pl_awinfo[5:0],pl_awlast[0]}
  .UserCustomOp_0_awwvalid  ( User_Ddr_awwvalid ),
  .UserCustomOp_0_awwready  ( User_Ddr_awwready ),

  .UserCustomOp_0_araddr    ( User_Ddr_araddr   ),
  .UserCustomOp_0_arvalid   ( User_Ddr_arvalid  ),
  .UserCustomOp_0_arinfo    ( User_Ddr_arinfo   ),  //{25'h0,pl_arinfo,pl_arlast}
  .UserCustomOp_0_arready   ( User_Ddr_arready  ),
  .UserCustomOp_0_rdata     ( User_Ddr_rdata    ),
  .UserCustomOp_0_rvalid    ( User_Ddr_rvalid   ),
  .UserCustomOp_0_rinfo     ( User_Ddr_rinfo    ),  //{25'h0,pl_rinfo,pl_rlast}
  .UserCustomOp_0_rready    ( User_Ddr_rready   ),

  //irq
  .customop_irq             (customop_irq             ),
  .ai_irq                   (ai_irq                  ),

  // ------------------------------------------------------------------------
  // The three inputs the vendor instance leaves floating. Vivado warns
  //   [Synth 8-350] requires 321 connections, but only 314 given
  // and the seven missing ones are exactly: pl_exhs, pl_exhs_vld, pl_exhs_ack,
  // pl_row_en_b[3:0], pl_col_en_b[3:0], pl_buyi_error, pl_scan_pipe_clk.
  // The four outputs can stay open, but a floating *input* reads as X, and
  // constant propagation over X inside the EDIF is a plausible source of the
  // driverless-net failures opt_design reports inside ZGolo (Opt 31-430 "FDCE
  // data pin undriven", Opt 31-67 "LUT2 missing I0"). Tie them off explicitly
  // and see whether opt_design gets further. This costs nothing if it does not.
  // The other four (pl_exhs_ack, pl_row_en_b, pl_col_en_b, pl_scan_pipe_clk)
  // stay unconnected: they are outputs, and an unconnected output is harmless.
  // ------------------------------------------------------------------------
  .pl_exhs                   ( 8'd0                    ),
  .pl_exhs_vld               ( 1'b0                    ),
  .pl_buyi_error             ( 1'b0                    )
);
`else

// --------------------------------------------------------------------------
// VIDEO-ONLY BUILD: the NPU is removed.
//
// impl_1 cannot get past opt_design with the NPU linked in, because the
// vendor AI_Mate netlist leaves nets undriven internally (Opt 31-430 /
// Opt 31-67). Those are inside the EDIF and cannot be fixed from RTL, so for
// the purpose of getting SDI video onto the board the NPU is taken out.
//
// The tie-offs below are exactly the nets the NPU used to DRIVE. From
// AI_Mate_stub.v:94-105 the NPU drives app_addr/app_cmd/app_en/app_wdf_*
// and consumes app_rd_data*/app_rdy/app_wdf_rdy. The first group is the
// mig_7series_0 user interface, so leaving it floating would just move the
// same driverless-LUT error into MIG.
//
// The second group is driven by MIG and is now simply unused.
//
// The video path is unaffected: frame_to_ps_largebuf sits on the PS AXI
// (M_AXI_GP0) and the PS has its own DDR, so SDI -> frame buffer -> HDMI
// does not involve the NPU or this MIG.
//
// Define WITH_NPU to restore the original design.
// --------------------------------------------------------------------------
assign app_addr        = 29'd0;
assign app_cmd         =  3'd0;
assign app_en          =  1'b0;
assign app_wdf_data    = 512'd0;
assign app_wdf_end     =  1'b0;
assign app_wdf_mask    = 64'd0;
assign app_wdf_wren    =  1'b0;

`endif


mig_7series_0 mig_ddr3_u0 (
  .ddr3_dq             (ddr3_dq            ),
  .ddr3_dqs_n          (ddr3_dqs_n         ),
  .ddr3_dqs_p          (ddr3_dqs_p         ),
  .ddr3_addr           (ddr3_addr          ),
  .ddr3_ba             (ddr3_ba            ),
  .ddr3_ras_n          (ddr3_ras_n         ),
  .ddr3_cas_n          (ddr3_cas_n         ),
  .ddr3_we_n           (ddr3_we_n          ),
  .ddr3_reset_n        (ddr3_reset_n       ),
  .ddr3_ck_p           (ddr3_ck_p          ),
  .ddr3_ck_n           (ddr3_ck_n          ),
  .ddr3_cke            (ddr3_cke           ),
  .ddr3_cs_n           (ddr3_cs_n          ),
  .ddr3_dm             (ddr3_dm            ),
  .ddr3_odt            (ddr3_odt           ),

  .init_calib_complete (ddr3_init_done     ),

  .app_addr            (app_addr           ),
  .app_cmd             (app_cmd            ),
  .app_en              (app_en             ),
  .app_wdf_data        (app_wdf_data       ),
  .app_wdf_end         (app_wdf_end        ),
  .app_wdf_wren        (app_wdf_wren       ),
  .app_rd_data         (app_rd_data        ),
  .app_rd_data_end     (app_rd_data_end    ),
  .app_rd_data_valid   (app_rd_data_valid  ),
  .app_rdy             (app_rdy            ),
  .app_wdf_rdy         (app_wdf_rdy        ),
  .app_wdf_mask        (app_wdf_mask       ),

  .app_sr_req          (1'b0               ),
  .app_ref_req         (1'b0               ),
  .app_zq_req          (1'b0               ),
  .app_sr_active       (                   ),
  .app_ref_ack         (                   ),
  .app_zq_ack          (                   ),

  .ui_clk              (ddr_clk            ),
  .ui_clk_sync_rst     (ddr_ui_rst         ),

  .sys_clk_p           (sys_clk_p          ),
  .sys_clk_n           (sys_clk_n          ),
  .device_temp_i       ('d0                ),  // input [11:0]			device_temp_i
  .sys_rst             (sys_rst            )
);

endmodule
