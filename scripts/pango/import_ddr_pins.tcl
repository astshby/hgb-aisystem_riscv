# Apply the vendor's FDC import procedures before generating the DDR IP.
source [file join [ui::getModelPath] ui.tcl]
upd_read_fdc
upd_auto_cfg_ca_dq_bank_group
upd_auto_cfg_ca_dq_pin
puts "PIN AUDIT DQ0=[ui::getValue -name PAD_DQ0] DQ31=[ui::getValue -name PAD_DQ31]"
