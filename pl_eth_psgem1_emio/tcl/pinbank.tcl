# 查 xc7z030ffg676-2 上 PL 网口那 15 个脚属于哪个 bank / 什么功能
set part xc7z030ffg676-2
link_design -part $part

set pins {AD23 AD26 AF24 AF25 AA24 AB24 AC23 AA25 AB26 AC26 AE25 AE26 AE22 AF22 AA13}

puts "PIN\tBANK\tPIN_FUNC\tIO_STANDARD_HINT"
foreach p $pins {
    set obj [get_package_pins -quiet $p]
    if {$obj eq ""} {
        puts "$p\tNOT_FOUND"
        continue
    }
    set func [get_property -quiet PIN_FUNC $obj]
    # PIN_FUNC 形如 IO_L11P_T1_SRCC_34，末段就是 bank 号
    if {[regexp {_(\d+)$} $func -> bank]} {
        puts "$p\t$bank\t$func"
    } else {
        puts "$p\t?\t$func"
    }
}

puts "---- 参考：已知同板 PL 脚 ----"
foreach p {F8 E7 AE23 AF23 AF15 AF14 J1 M6 H7 J8} {
    set obj [get_package_pins -quiet $p]
    if {$obj ne ""} {
        puts "$p\t[get_property -quiet PIN_FUNC $obj]"
    }
}

puts "---- bank 电压能力 ----"
foreach b [get_iobanks] {
    puts "bank [get_property -quiet BANK_NUMBER $b]  [get_property -quiet BANK_TYPE $b]"
}
