// nanomig.v

// turbo mode
// cpu and dma use different slots
//   copper and other dma runs on hpos[0] == 1
//   cpu runs in hpos[0] == 0
// -> run cpu on unused hpos[0] == 1 for turbo

module nanomig (
   input	 clk_sys,
   input	 reset,

   output	 clk7_en,
   output	 clk7n_en,

   // misc
   output	 pwr_led,
   output	 fdd_led,
   output	 hdd_led,

   // video
   output	 hs, // horizontal sync
   output	 vs, // vertical sync
   output [3:0]	 r,
   output [3:0]	 g,
   output [3:0]	 b,

   input [7:0]	 memory_config,
   input [5:0]	 chipset_config,
   input [3:0]	 floppy_config,
   input [3:0]	 video_config,
   input [5:0]	 ide_config,
		
   output [14:0] audio_left, // left DAC data
   output [14:0] audio_right, // right DAC data

   // mouse and keyboard
   input [2:0]	 mouse_buttons, // mouse buttons
   input	 kbd_mouse_level,
   input [1:0]	 kbd_mouse_type,
   input [7:0]	 kbd_mouse_data,
   input [7:0]	 joystick,

   // UART/RS232 for e.g. DiagROM or MIDI
   output	 uart_tx,
   input	 uart_rx,
		 
   // Interface MiSTeryNano sd card interface. This very simple connection allows the core
   // to request sectors from within a OSD selected image file
   input [7:0]	 sdc_img_mounted,
   input [31:0]	 sdc_img_size,
   output [7:0]	 sdc_rd,
   output [31:0] sdc_sector,
   input	 sdc_busy,
   input	 sdc_done,
   input	 sdc_byte_in_strobe,
   input [8:0]	 sdc_byte_in_addr,
   input [7:0]	 sdc_byte_in_data,
		
   // (s)ram interface
   output [15:0] ram_data,    // sram data bus
   input [15:0]	 ramdata_in,  // sram data bus in
   input [47:0]	 chip48,      // big chip read
   output        refresh,     // ram refresh cycle
   output [23:1] ram_address, // sram address bus
   output	 _ram_bhe,    // sram upper byte select
   output	 _ram_ble,    // sram lower byte select
   output	 _ram_we,     // sram write enable
   output	 _ram_oe      // sram output enable
);

reg reset_d;
always @(posedge clk_sys, posedge reset) begin
        reg [7:0] reset_s;
        reg rs;

        if(reset) reset_s <= '1;
        else begin
                reset_s <= reset_s << 1;
                rs <= reset_s[7];
                reset_d <= rs;
        end
end

//// amiga clocks ////
wire       c1;
wire       c3;
wire       cck;
wire [9:0] eclk;
// `define TEST_PHI_GEN
   
`ifdef TEST_PHI_GEN
reg [1:0]   mclkdiv;   
always @(posedge clk_sys) begin
   mclkdiv <= mclkdiv + 2'd1;  
end   
`endif // TEST_PHI_GEN
   
amiga_clk amiga_clk
(
`ifdef TEST_PHI_GEN
        .clk_28   ( mclkdiv[1] ), // input  clock c1 ( 28.687500MHz)
`else
        .clk_28   ( clk_sys    ), // input  clock c1 ( 28.687500MHz)
`endif
        .clk7_en  ( clk7_en    ), // output clock 7 enable (on 28MHz clock domain)
        .clk7n_en ( clk7n_en   ), // 7MHz negedge output clock enable (on 28MHz clock domain)
        .c1       ( c1         ), // clk28m clock domain signal synchronous with clk signal
        .c3       ( c3         ), // clk28m clock domain signal synchronous with clk signal delayed by 90 degrees
        .cck      ( cck        ), // colour clock output (3.54 MHz)
        .eclk     ( eclk       ), // 0.709379 MHz clock enable output (clk domain pulse)
        .reset_n  ( ~reset     )
);

// TODO: cpu_ph1 and cpu_ph2 are derived from a 114Mhz clock in original
// minimig aga. Current setting is taken from simulation:
// cpu_ph1 is valid before clk7_en and cpu_ph2 is after clk7_en
// so order is: cpu_ph1, clk7_en, cpu_ph2, clk7n_en
reg  cpu_ph1, cpu_ph2;
`ifndef TEST_PHI_GEN
always @(posedge clk_sys) begin
   if (~cpu_rst) begin
      cpu_ph1 <= 1'b0;
      cpu_ph2 <= 1'b0;
   end else begin 
//      cpu_ph1 <= !c1 &&  c3;  // on negedge clk_sys
//      cpu_ph2 <=  c1 && !c3;  // -"-
      cpu_ph1 <=   c1 &&  c3;
      cpu_ph2 <=  !c1 && !c3;
   end
end
   
`else   
reg  cyc;
always @(posedge clk_sys) begin
	reg [3:0] div;
	reg       c1d;

	div <= div + 1'd1;
	 
	c1d <= c1;
	if (~c1d & c1) div <= 3;
	
	if (~cpu_rst) begin
		cyc <= 0;
		cpu_ph1 <= 0;
		cpu_ph2 <= 0;
	end
	else begin
		cyc <= !div[1:0];
		if (div[1] & ~div[0]) begin
			cpu_ph1 <= 0;
			cpu_ph2 <= 0;
			case (div[3:2])
				0: cpu_ph2 <= 1;
				2: cpu_ph1 <= 1;
			endcase
		end
	end
end
`endif

wire  [1:0] cpu_state;
wire        cpu_nrst_out;
wire  [3:0] cpu_cacr;
wire [31:0] cpu_nmi_addr;

wire  [2:0] chip_ipl;
wire        chip_dtack;
wire        chip_as;
wire        chip_uds;
wire        chip_lds;
wire        chip_rw;
wire [15:0] chip_dout;
wire [15:0] chip_din;
wire [23:1] chip_addr;

wire	    ovl;
   
wire [1:0] cpucfg = 2'b00;     // 68020=11
// cache bits: dcache, kick, chip
// wire [2:0] cachecfg = { 1'b0, ~ovl, 1'b0 };
wire [2:0] cachecfg = 3'b000;  // no turbo chip and kick, no caches   
// wire [2:0] cachecfg = 3'b010;  // permanent turbo kick

// -------------- fast(er) ram interface used in turbo mode --------------

// This implements a direct path for the CPU to access ram. This can be used
// whenever the RAM is unused by the chipset itself (DMA) to give the CPU
// faster access than usual. With the tg68k this can be used to speed up
// the system significantly. Since Kickstart is also stored in ram, this also
// speeds up kickstart rom access.
   
wire	   _ram_oe_i;
assign _ram_oe = ~(~_ram_oe_i || ram_cs);   
   
wire [15:0] ram_dout = ramdata_in;   
wire [28:1] ram_addr;   
wire	    ram_sel;
wire	    ram_lds;
wire	    ram_uds;
   
// ram_ready finally is the clkena for the tg68k
reg	    ram_ready;

// generate a ram_cs at the begin of the bus cycle, so the ram cycle starts
// at the right time
wire	    ram_cs = (cpu_ph2 && ram_sel) || ram_cs_trigger || ram_cs_triggerD; 

reg	    ram_cs_trigger;   
always @(negedge clk_sys)
   if( cpu_ph2 )      ram_cs_trigger <= ram_sel;
   else if( clk7_en ) ram_cs_trigger <= 1'b0;   

reg	    ram_cs_triggerD;
always @(posedge clk_sys)
  ram_cs_triggerD <= ram_cs_trigger;   
   
// neg/clk7
always @(negedge clk_sys) begin
   if( clk7_en )
     // only generate ready when the chipset is not accessing ram
     ram_ready <= _ram_oe_i && ram_cs;
   else
     ram_ready <= 1'b0;
end
   
cpu_wrapper cpu_wrapper
(
	.reset        (cpu_rst         ),
	.reset_out    (cpu_nrst_out    ),

	.clk          (clk_sys         ),
	.ph1          (cpu_ph1         ),
	.ph2          (cpu_ph2         ),

	.chip_addr    (chip_addr       ),
	.chip_dout    (chip_dout       ),
	.chip_din     (chip_din        ),
	.chip_as      (chip_as         ),
	.chip_uds     (chip_uds        ),
	.chip_lds     (chip_lds        ),
	.chip_rw      (chip_rw         ),
	.chip_dtack   (chip_dtack      ),
	.chip_ipl     (chip_ipl        ),

	.fastchip_dout   (  ),
	.fastchip_sel    (  ),
	.fastchip_lds    (  ),
	.fastchip_uds    (  ),
	.fastchip_rnw    (  ),
	.fastchip_selack (  ),
	.fastchip_ready  ( 1'b0 ),
	.fastchip_lw     (  ),

	.cpucfg       (cpucfg          ),
	.cachecfg     (cachecfg        ),
	.fastramcfg   (3'd0            ),
	.bootrom      (1'b0            ),

	.ramsel       (ram_sel         ),
	.ramaddr      (ram_addr        ),
	.ramlds       (ram_lds         ),
	.ramuds       (ram_uds         ),
	.ramdout      (ram_dout        ),
	.ramdin       (                ),
	.ramready     (ram_ready       ),
	.ramshared    (                ),

	//custom CPU signals
	.cpustate     (cpu_state       ),
	.cacr         (cpu_cacr        ),
	.nmi_addr     (cpu_nmi_addr    )
);

// ==============================================================================
// ===================================== IDE ====================================
// ==============================================================================

// In a real minimig much of the IDE specific stuff is done on the
// microcontroller side. The concept of NanoMig (and MiSTeryNano)
// differs from this as only the necessary stuff is done on MCU
// side. Things that are hardware specific all happen in the
// FPGA. This includes the entire IDE handling.


// TODO:
// - clear IDE1 registers in startup
// - use dpram
  
// main state machine
reg [2:0] ide_state;
localparam IDE_STATE_INIT     = 3'd0;  // state directly after reset
localparam IDE_STATE_WAIT4CMD = 3'd1;
localparam IDE_STATE_EXEC_CMD = 3'd2;

reg [2:0] ide_exec;
localparam IDE_EXEC_IDLE           = 3'd0;
localparam IDE_EXEC_SET_CONFIG     = 3'd1;
localparam IDE_EXEC_SET_REGS       = 3'd2;
localparam IDE_EXEC_GET_REGS       = 3'd3;
localparam IDE_EXEC_SEND_IDENTIFY  = 3'd4;
localparam IDE_EXEC_SEND_PAYLOAD   = 3'd5;
localparam IDE_EXEC_READ_SECTOR    = 3'd6;

reg [8:0] ide_exec_cnt;
      
// ide commands used by kickstart 3.1 in order of usage:
// 0x10 -> initialize disk. Immediately IRQ & RDY
// 0xec -> identify drive, sends 256 words of drive description   
// 0x91 ->
reg [7:0] ide_cmd;   
     
// status bits:
// 0 - error in error register is valid
// 1 - last read
// 2 - ecc correction happened, (ab)used for IRQ signalling here
// 3 - DRQ bit
// 4 - success bit (SKC)
// 5 - write error bit (WFT), (ab)used to signal fast read here
// 6 - ready bit (RDY)
// 7 - busy bit (BSY)

reg [7:0]  ide_status;  
reg [7:0]  ide_error;   
   
reg [7:0]  ide_spb;
reg [15:0] ide_cylinder;
reg [7:0]  ide_sector;
reg [3:0]  ide_head;   
reg [7:0]  ide_sector_cnt;
reg [7:0]  ide_sdc_cnt;
reg [7:0]  ide_io_size;   
   
reg	   ide_io_done;
reg	   ide_io_fast;
reg [7:0]  ide_features;   
reg	   ide_drv;

reg	   ide_disk_present = 0;   
reg	   ide_sdc_rd;
reg	   ide_sdc_parse_rdb = 0;   
reg [31:0] ide_sdc_sector;   
   
wire [31:0] sdc_sector_int;  // from inside minimig/floppy
assign sdc_sector = ide_sdc_rd?ide_sdc_sector:sdc_sector_int;      
assign sdc_rd[7:4] = { 3'b000, ide_sdc_rd }; 
   
// default drive parameters. Should be taken from RDB sector 0   
reg [15:0] cylinders;
reg [15:0] sectors;
reg [15:0] heads;

// total sectors could be calculated from cylinders * sectors * heads
// which requires DSP units. Instead we simply use the image size
// divided by 512
reg [31:0] total_sectors;

reg	   debug = 1'b0;   
//assign hdd_led = debug;   
     
always @(posedge clk_sys) begin
   if (sdc_img_mounted[4]) begin
      if( !sdc_img_size )
	 ide_disk_present <= 1'b0;
      else if (!sdc_busy && !ide_sdc_rd) begin  
	 // image has just been mounted. Examine it further
	 // by reading first sector.      
	 ide_sdc_sector <= 32'd0;	
	 ide_sdc_rd <= 1'b1;
	 total_sectors <= { 9'd0, sdc_img_size[31:9] };	 
      end
   end
   
   // amiga wants to read a sector
   if ( !sdc_busy && !ide_sdc_rd && ide_exec == IDE_EXEC_READ_SECTOR ) begin
      // this does hurt the fpga ...
      ide_sdc_sector <= (ide_cylinder * heads + ide_head) * sectors +
			ide_sector - 1;
      
      ide_sdc_rd <= 1'b1;
   end
   
   // sd card has accepted request
   if ( ide_sdc_rd && sdc_busy ) begin
      ide_sdc_rd <= 1'b0;

      // parse rdb unless the amiga has requested this sector
      if( ide_exec != IDE_EXEC_READ_SECTOR )
	ide_sdc_parse_rdb <= 1'b1;      
   end

   // parsing the rdb in sector 0 of the harddisk image
   // gives the cylinders, heads and sectors to be used
   if ( ide_sdc_parse_rdb && sdc_byte_in_strobe ) begin
      case ( sdc_byte_in_addr )
	// check for 'RDSK' header and stop parsing if that fails
	0: if ( sdc_byte_in_data != "R") ide_sdc_parse_rdb <= 1'b0;
	1: if ( sdc_byte_in_data != "D") ide_sdc_parse_rdb <= 1'b0;
	2: if ( sdc_byte_in_data != "S") ide_sdc_parse_rdb <= 1'b0;
	3: if ( sdc_byte_in_data != "K") ide_sdc_parse_rdb <= 1'b0;	
	
	// long word 16 contains cylinders
	16*4+2: cylinders[15:8] <= sdc_byte_in_data;
	16*4+3: cylinders[ 7:0] <= sdc_byte_in_data;
	// long word 17 contains sectors
	17*4+2: sectors[15:8] <= sdc_byte_in_data;
	17*4+3: sectors[ 7:0] <= sdc_byte_in_data;
	// long word 18 contains heads
	18*4+2: heads[15:8] <= sdc_byte_in_data;
	18*4+3: heads[ 7:0] <= sdc_byte_in_data;

	511: begin
	   ide_sdc_parse_rdb <= 1'b0;
	   ide_disk_present <= 1'b1;
	end
      endcase // case ( sdc_byte_in_addr )      
   end
end
   
always @(posedge clk_sys) begin
   if(reset) begin
      ide_state <= IDE_STATE_INIT;      
      ide_exec <= IDE_EXEC_IDLE;
      ide_cmd <= 8'h00;      

      // set default register contents
      ide_io_done <= 1'b0;
      ide_io_fast <= 1'b0;
      ide_features <= 8'h00;

      ide_spb        <= 8'd16;      
      ide_error      <= 8'h00;      
      ide_status     <= 8'h00;
      ide_drv        <= 1'b0;      
      ide_cylinder   <= 16'd0;
      ide_sector     <= 8'd1;
      ide_sector_cnt <= 8'd0;
      ide_io_size    <= 8'd1;
   end else begin
      case (ide_state)
	// system has started and just got out of reset
	IDE_STATE_INIT: begin
	   // if the execution engine is idle and a IDE disk image has been
	   // mounted, then configue ide0
	   if(ide_exec == IDE_EXEC_IDLE && ide_disk_present) begin
	      ide_status <= 8'b0100_0000;  // drive ready

	      ide_exec <= IDE_EXEC_SET_CONFIG;
	      ide_exec_cnt <= 9'd0;
	   end
	end

	// system is waiting for IDE command from core
	IDE_STATE_WAIT4CMD: begin
	   // check if a command request has been received for ide0
	   // ide1 is currently not supported (and so is ide0 slave)
	   if(ide_request[2:0] == 3'b100) begin
	      // new command received
	      ide_status <= 8'h00;    // clear status
	      ide_error <= 8'h00;     // clear error

	      // read registers once a command has been received
	      ide_state <= IDE_STATE_EXEC_CMD;
	      ide_exec <= IDE_EXEC_GET_REGS;
	      ide_exec_cnt <= 9'd0;	      
	   end

	   // request to continue a multi sector transfer that
	   // exceeds the max io size
	   if(ide_request[2:0] == 3'b101) begin
	      ide_state <= IDE_STATE_EXEC_CMD;

	      // jump right to next read
	      ide_exec <= IDE_EXEC_READ_SECTOR;
	      ide_exec_cnt <= 9'd0;

	      // check how many sectors can be sent in this
	      // transfer
	      if ( ide_sector_cnt < ide_spb ) begin
		 ide_sdc_cnt <= ide_sector_cnt;
		 ide_io_size <= ide_sector_cnt;
	      end else begin
                 ide_sdc_cnt <= ide_spb;
		 ide_io_size <= ide_spb;
	      end
	   end
	end

	// system is processing an IDE command
	IDE_STATE_EXEC_CMD: begin

	end
	   
      endcase // case (ide_state)

      case (ide_exec)

	IDE_EXEC_SET_CONFIG: begin
	   // this state is only ever reached if a disk image
	   // has been detected
	   
	   // send just 1 register word
	   if ( ide_exec_cnt != { 8'd0, 1'b1 } )
	     ide_exec_cnt <= ide_exec_cnt + 9'd1;
	   else begin
	      // done sending config word, now send registers if disk present
	      ide_exec <= IDE_EXEC_SET_REGS;
	      ide_exec_cnt <= 9'd0;	      
	   end
	end

	IDE_EXEC_SEND_PAYLOAD: begin
	   // transmit 256 words of payload
	   if ( sdc_byte_in_strobe && sdc_byte_in_addr == 9'd511 ) begin
	      // decrease sector counter and increase sector number. This
	      // is actually a hack as the increase should happen over
	      // sector/head/cylinder. But this should work for now
	      ide_sector_cnt <= ide_sector_cnt - 8'd1;

	      // advance to next sector
	      // ide_sector goes from 1 to sectors,
	      // ide_head goes from 0 to heads-1
	      if ( ide_sector < sectors )
		ide_sector <= ide_sector + 8'd1;
	      else begin
		 ide_sector <= 8'd1;
		 if( ide_head < heads-1 )
		   ide_head <= ide_head + 8'd1;
		 else begin
		    ide_head <= 8'd0;
		    ide_cylinder <= ide_cylinder + 16'd1;
		 end
	      end
	      
	      ide_sdc_cnt <= ide_sdc_cnt - 8'd1;	      
	      
	      if ( ide_sdc_cnt <= 1 ) begin
		 // finally send the registers incl irq		 
		 ide_status[3:2] <= 2'b11;  // raise irq and drq

		 // all requested sectors sent?
		 if( ide_sector_cnt <= 1 )
		   ide_status[1] <= 1'b1; // set 'last read' flag

		 ide_exec <= IDE_EXEC_SET_REGS;
		 ide_exec_cnt <= 9'd0;
	      end else begin
		 // jump right to next read
		 ide_exec <= IDE_EXEC_READ_SECTOR;
		 ide_exec_cnt <= 9'd0;
	      end
	   end
	end
	
	IDE_EXEC_SEND_IDENTIFY: begin
	   // transmit 256 words of drive identification data
	   if ( ide_exec_cnt != { 8'd255, 1'b1 } )
	     ide_exec_cnt <= ide_exec_cnt + 9'd1;
	   else begin
	      // finally send the registers incl irq
	      ide_status[3:0] <= 4'b1110;  // raise irq, drq, last read
	      ide_exec <= IDE_EXEC_SET_REGS;
	      ide_exec_cnt <= 9'd0;	      	      
	   end
	end
	
	IDE_EXEC_READ_SECTOR: begin
	   // sd card has accepted request
	   if ( ide_sdc_rd && sdc_busy ) begin
	      ide_exec <= IDE_EXEC_SEND_PAYLOAD;
	   end
	end

	IDE_EXEC_GET_REGS: begin
	   // process incoming data
	   if ( ide_exec_cnt[0] ) begin
	      case (ide_exec_cnt[5:1])
		0: begin 
		   ide_features <= ide_readdata[15:8];
		   ide_io_fast  <= ide_readdata[1];
		   ide_io_done  <= ide_readdata[0];
		end
		1: { ide_sector, ide_sector_cnt } <= ide_readdata;
		2: ide_cylinder <= ide_readdata;
		//3: { ide_sector[15:8], ide_sector_cnt[15:8] } <= ide_readdata;
		//4: ide_cylinder[31:16] <= ide_readdata;
		5: begin
		   // bit 7 and 5 should always be 1
		   ide_cmd  <= ide_readdata[15:8];
		   ide_drv  <= ide_readdata[4];
		   ide_head <= ide_readdata[3:0];
		end
	      endcase
	   end // if ( ide_exec_cnt[0] )
	   
	   // receive 6 register words
	   if ( ide_exec_cnt != { 8'd5, 1'b1 } )
	     ide_exec_cnt <= ide_exec_cnt + 9'd1;
	   else if(!ide_readdata[4] /* -> ide_drv */) begin
	      // for now only master (drv == 0) is supported
	      ide_status <= 8'b0100_0000;  // drive ready

	      // done receiving registers, determine how to
	      // continue. Now the ide_cmd is valid and can
	      // be examined
	      if ( ide_readdata[15:12] /* -> ide_cmd[7:4] */ == 4'h1 ) begin
		 // command 1x: initialize
		 // this command is just acknowledged without
		 // any further action
		 ide_status[2] <= 1'b1;  // raise irq
		 
		 // write registers incl the status
		 ide_exec <= IDE_EXEC_SET_REGS;
		 ide_exec_cnt <= 9'd0;	      
		 
	      end else if ( ide_readdata[15:8] /* -> ide_cmd */ == 8'hec ) begin
		 // command ec: identify drive
		 // sends 256 words of drive description
		 ide_exec <= IDE_EXEC_SEND_IDENTIFY;
		 ide_exec_cnt <= 9'd0;	      
		 
	      end else if ( ide_readdata[15:12] /* -> ide_cmd[7:4] */ == 4'h2 ) begin
		 // command 2x: read
		 // sends 256 words of actual payload

		 // request sector from sd card
		 ide_sdc_cnt <= 8'd1;				  
		 ide_io_size <= 8'd1;
		 
		 ide_exec <= IDE_EXEC_READ_SECTOR;		 		 
		 ide_exec_cnt <= 9'd0;	      
		 
	      end else if ( ide_readdata[15:8] /* -> ide_cmd */ == 8'hc4 ) begin
		 // command c4: read multiple
		 // sends cnt * 256 words of actual payload

		 // request sectors from sd card		 
		 // check how many sectors can be sent in this transfer
		 if ( ide_sector_cnt < ide_spb ) begin
		    ide_sdc_cnt <= ide_sector_cnt;
		    ide_io_size <= ide_sector_cnt;
		 end else begin
                    ide_sdc_cnt <= ide_spb;
		    ide_io_size <= ide_spb;
		 end
		 
		 ide_exec <= IDE_EXEC_READ_SECTOR;		 		 
		 ide_exec_cnt <= 9'd0;	      
		 
	      end else if (ide_readdata[15:8] /* ->  ide_cmd */ == 8'h91 ) begin
		 // command 91: set drive parameters
		 ide_status[2] <= 1'b1;  // raise irq
		 ide_exec <= IDE_EXEC_SET_REGS;
		 ide_exec_cnt <= 9'd0;	      

	      end else if ( ide_readdata[15:8] /* -> ide_cmd */ == 8'hc6) begin
		 // command c6: set multiple
		 ide_spb <= ide_sector_cnt;
		 		 
		 ide_status[2] <= 1'b1;  // raise irq
		 ide_exec <= IDE_EXEC_SET_REGS;
		 ide_exec_cnt <= 9'd0;	      
		 
	      end else begin
		 // unknown command
		 ide_status[0] <= 1'b1;  // raise error
		 ide_status[2] <= 1'b1;  // raise irq
		 ide_error <= 8'h04;     // abort
		 
		 ide_exec <= IDE_EXEC_SET_REGS;
		 ide_exec_cnt <= 9'd0;	      
	      end
	   end else begin // if (!ide_drv)
	      // slave is currently not supported
	      ide_status[0] <= 1'b1;  // raise error
	      ide_status[2] <= 1'b1;  // raise irq
	      ide_error <= 8'h04;     // abort
	      
	      ide_exec <= IDE_EXEC_SET_REGS;
	      ide_exec_cnt <= 9'd0;	      
	   end
	end
	
	IDE_EXEC_SET_REGS: begin
	   // send 6 register words
	   if ( ide_exec_cnt != { 8'd5, 1'b1 } )
	     ide_exec_cnt <= ide_exec_cnt + 9'd1;
	   else begin
	      debug <= 1'b1;
		 
	      // done sending registers
	      ide_state <= IDE_STATE_WAIT4CMD;
	      ide_exec <= IDE_EXEC_IDLE;
	      ide_exec_cnt <= 9'd0;
	   end
	end
	
      endcase
      
   end
end   

// IDE management signals   
wire [15:0] ide_writedata;   
wire [15:0] ide_readdata;   

// ide requests:
// 110 - reset
// 000 - write to mgmt address 5
// 100 - new command
// 101 - data send/recv
wire [5:0] ide_request;

// IDE identify device reply
wire [15:0] ide_identify_data =
	    (ide_exec_cnt[8:1] ==  8'd0)?16'h0040:  //word 0
	    (ide_exec_cnt[8:1] ==  8'd1)?cylinders: //word 1
	    //word 2 reserved
	    (ide_exec_cnt[8:1] ==  8'd3)?heads:	    //word 3
	    //word 4 obsolete
	    //word 5 obsolete
	    (ide_exec_cnt[8:1] ==  8'd6)?sectors:   //word 6
	    //word 7 vendor specific
	    //word 8 vendor specific
	    //word 9 vendor specific
	    (ide_exec_cnt[8:1] == 8'd10)?"AO":	//word 10
	    (ide_exec_cnt[8:1] == 8'd11)?"HD":	//word 11
	    (ide_exec_cnt[8:1] == 8'd12)?"00":	//word 12
	    (ide_exec_cnt[8:1] == 8'd13)?"00":	//word 13
	    (ide_exec_cnt[8:1] == 8'd14)?"0 ":	//word 14
	    (ide_exec_cnt[8:1] == 8'd15)?"  ":	//word 15
	    (ide_exec_cnt[8:1] == 8'd16)?"  ":	//word 16
	    (ide_exec_cnt[8:1] == 8'd17)?"  ":	//word 17
	    (ide_exec_cnt[8:1] == 8'd18)?"  ":	//word 18
	    (ide_exec_cnt[8:1] == 8'd19)?"  ":	//word 19
	    (ide_exec_cnt[8:1] == 8'd20)?16'd3:	//word 20 buffer type
	    (ide_exec_cnt[8:1] == 8'd21)?16'd512:	//word 21 cache size
	    (ide_exec_cnt[8:1] == 8'd22)?16'd4:	//word 22 number of ecc bytes
	    //words 23..26 firmware revision
	    ((ide_exec_cnt[8:1] >= 8'd27)&&(ide_exec_cnt[8:1] <= 8'd46))?"  ": //words 27..46 model number
	    (ide_exec_cnt[8:1] == 8'd47)?16'h8020:	//word 47 max multiple sectors
	    (ide_exec_cnt[8:1] == 8'd48)?16'd1:	//word 48 dword io
	    (ide_exec_cnt[8:1] == 8'd49)?16'b0000_0000_0000_0000: // 9 - word 49 lba not supported
	    (ide_exec_cnt[8:1] == 8'd50)?16'h4001:	//word 50 reserved
	    (ide_exec_cnt[8:1] == 8'd51)?16'h0200:	//word 51 pio timing
	    (ide_exec_cnt[8:1] == 8'd52)?16'h0200:	//word 52 pio timing
	    (ide_exec_cnt[8:1] == 8'd53)?16'h0007:	//word 53 valid fields
	    (ide_exec_cnt[8:1] == 8'd54)?cylinders:     //word 54
	    (ide_exec_cnt[8:1] == 8'd55)?heads:	        //word 55
	    (ide_exec_cnt[8:1] == 8'd56)?sectors:       //word 56
	    (ide_exec_cnt[8:1] == 8'd57)?total_sectors[15:0]://word 57
	    (ide_exec_cnt[8:1] == 8'd58)?total_sectors[31:16]://word 58
	    (ide_exec_cnt[8:1] == 8'd59)?16'h110:	//word 59 multiple sectors
	    //word 60 LBA-28
	    //word 61 LBA-28
	    //word 62 single word dma modes
	    //word 63 multiple word dma modes
	    //word 64 pio modes
	    (ide_exec_cnt[8:1] == 8'd65)?16'd120:       //word 65..68
	    (ide_exec_cnt[8:1] == 8'd66)?16'd120:
	    (ide_exec_cnt[8:1] == 8'd67)?16'd120:
	    (ide_exec_cnt[8:1] == 8'd68)?16'd120:
	    //word 69..79
	    (ide_exec_cnt[8:1] == 8'd80)?16'h007E:	//word 80 ata modes
	    //word 81 minor version number
	    (ide_exec_cnt[8:1] == 8'd82)?16'b0100_0010_0000_0000: // 14, 9 - word 82 supported commands
	    (ide_exec_cnt[8:1] == 8'd83)?16'b0111_0000_0000_0000: // 14, 13, 12 - word 83
	    (ide_exec_cnt[8:1] == 8'd84)?16'b0100_0000_0000_0000: // 14 - word 84
	    (ide_exec_cnt[8:1] == 8'd85)?16'b0100_0010_0000_0000: // 14, 9 - word 85
	    (ide_exec_cnt[8:1] == 8'd86)?16'b0111_0000_0000_0000: // 14, 13, 12 - word 86
	    (ide_exec_cnt[8:1] == 8'd87)?16'b0100_0000_0000_0000: // 14 - word 87
	    //word 88
	    //word 89..92
	    (ide_exec_cnt[8:1] == 8'd93)?16'b0110_0011_0000_1011: // 14, 13, 9, 8, 3, 1, 0 - word 93
	    //word 94..99
	    //word 100 LBA-48
	    //word 101 LBA-48
	    //word 102 LBA-48
	    //word 103 LBA-48
	    16'h0000;
      
wire [4:0] ide_address = { 1'b0,                                // only support master by now
	   (ide_exec == IDE_EXEC_SET_CONFIG)?4'd6:              // config is management register 6
	   (ide_exec == IDE_EXEC_SET_REGS)?ide_exec_cnt[4:1]:   // write registers via mgmt registers 0 .. 5
	   (ide_exec == IDE_EXEC_GET_REGS)?ide_exec_cnt[4:1]:   // read -"-
	   (ide_exec == IDE_EXEC_SEND_IDENTIFY)?4'd15:          // data transfer from/to ide0 via register 15
	   (ide_exec == IDE_EXEC_READ_SECTOR)?4'd15:            // -"-
	   (ide_exec == IDE_EXEC_SEND_PAYLOAD)?4'd15:           // -"-
	   4'd0 };   

// data for "set register"
wire [15:0] ide_set_register_data =
     (ide_exec_cnt[4:1] == 4'd0)?{ide_error, ide_io_size}:             // error, io size
     (ide_exec_cnt[4:1] == 4'd1)?{ide_sector, ide_sector_cnt}:         // sector, sector_count
     (ide_exec_cnt[4:1] == 4'd2)?ide_cylinder:                         // cylinder
     (ide_exec_cnt[4:1] == 4'd3)?16'h0000:                             // sector hi, sector_count hi
     (ide_exec_cnt[4:1] == 4'd4)?16'h0000:                             // cylinder high
     (ide_exec_cnt[4:1] == 4'd5)?{ide_status,3'b101,ide_drv,ide_head}: // status, drv_addr
     16'h00_00;

// assemble words from bytes
reg [7:0] sdc_even_byte;   
always @(posedge clk_sys)
  if ( sdc_byte_in_strobe && !sdc_byte_in_addr[0] )
    sdc_even_byte <= sdc_byte_in_data;

wire [15:0] ide_payload_data = { sdc_byte_in_data, sdc_even_byte };  
	    
// multiplex data to be written to the ide management interface   
assign ide_writedata =
      (ide_exec == IDE_EXEC_SEND_IDENTIFY)?ide_identify_data:
      (ide_exec == IDE_EXEC_READ_SECTOR)?ide_payload_data:
      (ide_exec == IDE_EXEC_SEND_PAYLOAD)?ide_payload_data:
      (ide_exec == IDE_EXEC_SET_REGS)?ide_set_register_data:
      (ide_exec == IDE_EXEC_SET_CONFIG && ide_disk_present)?16'h00_0f:
      (ide_exec == IDE_EXEC_SET_CONFIG)?16'h00_0f:
      16'h0000;

// there some side effects of this besides writing the data itself
// writing to address 5
   // clears the request
   // clears io_wait
   // bit[13]: fast read
   // bit[10]: irq
   // bit[9]:  last_read

// generate read and write signals for the ide management interface   
wire ide_read = !ide_exec_cnt[0] &&
     (ide_exec == IDE_EXEC_GET_REGS); 
   
wire ide_write = (!ide_exec_cnt[0] && (
     (ide_exec == IDE_EXEC_SET_CONFIG) || 
     (ide_exec == IDE_EXEC_SET_REGS) || 
     (ide_exec == IDE_EXEC_SEND_IDENTIFY))

     // forward the word every seconds byte received from the sd card
     ||(ide_exec == IDE_EXEC_SEND_PAYLOAD && sdc_byte_in_strobe && sdc_byte_in_addr[0]));

///////////////////////////////////////////////////////////////////////

// apply blanking to video. May actually not be needed as the HDMI
// encoder does its own blanking. But it's nice for simulation
wire [7:0] red, green, blue;   
wire	   hbl, vbl;
wire [8:0] htotal;   
wire [3:0] r_in = (hbl||vbl)?4'h0:red[7:4];
wire [3:0] g_in = (hbl||vbl)?4'h0:green[7:4];
wire [3:0] b_in = (hbl||vbl)?4'h0:blue[7:4];   

wire [1:0] res;   
wire	   hs_in, vs_in;   

// JOY0 is actually the joystick port and and joy1 is being driven by usb mouse data
// JOY2 and JOY3 
wire [15:0] JOY0 = { 8'h0, joystick };   
wire [15:0] JOY1 = 16'h0000;
wire [15:0] JOY2 = 16'h0000;
wire [15:0] JOY3 = 16'h0000;   

minimig minimig
(
	//m68k pins
	.cpu_address  (chip_addr        ), // M68K address bus
	.cpu_data     (chip_dout        ), // M68K data bus
	.cpudata_in   (chip_din         ), // M68K data in
	._cpu_ipl     (chip_ipl         ), // M68K interrupt request
	._cpu_as      (chip_as          ), // M68K address strobe
	._cpu_uds     (chip_uds         ), // M68K upper data strobe
	._cpu_lds     (chip_lds         ), // M68K lower data strobe
	.cpu_r_w      (chip_rw          ), // M68K read / write
	._cpu_dtack   (chip_dtack       ), // M68K data acknowledge
	._cpu_reset   (cpu_rst          ), // M68K reset
	._cpu_reset_in(cpu_nrst_out     ), // M68K reset out
	.nmi_addr     (cpu_nmi_addr     ), // M68K NMI address

        .memory_config (memory_config   ), // ram sizes
        .chipset_config(chipset_config  ), 
        .floppy_config (floppy_config   ), 
        .ide_config    (ide_config      ), 

	//sram pins
	.ram_data     (ram_data         ), // SRAM data bus
	.ramdata_in   (ramdata_in       ), // SRAM data bus in
	.ram_address  (ram_address      ), // SRAM address bus
	._ram_bhe     (_ram_bhe         ), // SRAM upper byte select
	._ram_ble     (_ram_ble         ), // SRAM lower byte select
	._ram_we      (_ram_we          ), // SRAM write enable
	._ram_oe      (_ram_oe_i        ), // SRAM output enable
	.chip48       (chip48           ), // big chipram read
	.refresh      (refresh          ), // current bus cycle is refresh

	//system  pins
	.rst_ext      (reset_d          ), // reset from ctrl block
	.rst_out      (                 ), // minimig reset status
	.clk          (clk_sys          ), // output clock c1 ( 28.687500MHz)
	.clk7_en      (clk7_en          ), // 7MHz clock enable
	.clk7n_en     (clk7n_en         ), // 7MHz negedge clock enable
	.c1           (c1               ), // clk28m clock domain signal synchronous with clk signal
	.c3           (c3               ), // clk28m clock domain signal synchronous with clk signal delayed by 90 degrees
	.cck          (cck              ), // colour clock output (3.54 MHz)
	.eclk         (eclk             ), // 0.709379 MHz clock enable output (clk domain pulse)
        .ovl          (ovl              ),   

	//rs232 pins
	.rxd          (uart_rx          ), // RS232 receive
	.txd          (uart_tx          ), // RS232 send
	.cts          (uart_cts         ), // RS232 clear to send
	.rts          (uart_rts         ), // RS232 request to send
	.dtr          (uart_dtr         ), // RS232 Data Terminal Ready
	.dsr          (uart_dsr         ), // RS232 Data Set Ready
	.cd           (uart_dsr         ), // RS232 Carrier Detect
	.ri           (1                ), // RS232 Ring Indicator

	//I/O
	._joy1        (~JOY0            ), // joystick 1 [fire4,fire3,fire2,fire,up,down,left,right] (default mouse port)
	._joy2        (~JOY1            ), // joystick 2 [fire4,fire3,fire2,fire,up,down,left,right] (default joystick port)
	._joy3        (~JOY2            ), // joystick 3 [fire4,fire3,fire2,fire,up,down,left,right]
	._joy4        (~JOY3            ), // joystick 4 [fire4,fire3,fire2,fire,up,down,left,right]
	.joya1        (JOYA0            ),
	.joya2        (JOYA1            ),
	.mouse_btn    (mouse_buttons    ), // mouse buttons
	.kbd_mouse_data (kbd_mouse_data ), // mouse direction data, keycodes
	.kbd_mouse_type (kbd_mouse_type ), // type of data
	.kms_level    (kbd_mouse_level  ),
	.pwr_led      (pwr_led          ), // power led
	.fdd_led      (fdd_led          ),
	.hdd_led      (hdd_led          ),
	.rtc          (RTC              ),

	//host controller interface (SPI)
	.IO_UIO       (io_uio           ),
	.IO_FPGA      (io_fpga          ),
	.IO_STROBE    (io_strobe        ),
	.IO_WAIT      (io_wait          ),
	.IO_DIN       (io_din           ),
	.IO_DOUT      (fpga_dout        ),

	//video
	._hsync       (hs_in            ), // horizontal sync
	._vsync       (vs_in            ), // vertical sync
	.field1       (field1           ),
	.lace         (lace             ),
	.red          (red              ), // red
	.green        (green            ), // green
	.blue         (blue             ), // blue
	.hblank       (hbl              ),
	.vblank       (vbl              ),
	.ar           (                 ),
	.scanline     (fx               ),
	//.ce_pix     (ce_pix           ),
	.res          (res              ),
        .htotal       (htotal           ),

	//audio
	.ldata        (audio_left       ), // left DAC data
	.rdata        (audio_right      ), // right DAC data
	.ldata_okk    (                 ), // 9bit
	.rdata_okk    (                 ), // 9bit

	.aud_mix      (                 ),

	//user i/o
	.cpucfg       (cpucfg ), // CPU config
	.cachecfg     (cachecfg ), // Cache config
	.memcfg       ( ), // memory config
	.bootrom      ( ), // bootrom mode. Needed here to tell tg68k to also mirror the 256k Kickstart 

        // sd card interface for floppy disk emulation
        .sdc_img_mounted    ( sdc_img_mounted[3:0]),
        .sdc_img_size       ( sdc_img_size        ),  // length of image file
        .sdc_rd             ( sdc_rd[3:0]         ),
        .sdc_sector         ( sdc_sector_int      ),
        .sdc_busy           ( sdc_busy            ),
        .sdc_done           ( sdc_done            ),
	.sdc_byte_in_strobe ( sdc_byte_in_strobe  ),
	.sdc_byte_in_addr   ( sdc_byte_in_addr    ),
	.sdc_byte_in_data   ( sdc_byte_in_data    ),
 
	.ide_fast     (                 ),
	.ide_ext_irq  ( 1'b0            ),
	.ide_ena      (                 ),
	.ide_req      ( ide_request     ),
	.ide_address  ( ide_address     ),
	.ide_write    ( ide_write       ),
	.ide_writedata( ide_writedata   ),
	.ide_read     ( ide_read        ),
	.ide_readdata ( ide_readdata    )
);

Amber AMBER
(
	.clk28m(clk_sys),
	.lr_filter(video_config[3:2]),	//interpolation filters settings for low resolution
	.hr_filter(video_config[3:2]),	//interpolation filters settings for high resolution
	.scanline(video_config[1:0]),	//scanline effect enable
	.htotal(htotal[8:1]),		//video line length
	.hires(res[0]),			//display is in hires mode (from bplcon0)
	.dblscan(1'b1),			//enable VGA output (enable scandoubler)
	.red_in(r_in), 			//red componenent video in
	.green_in(g_in),  		//green component video in
	.blue_in(b_in),			//blue component video in
	._hsync_in(hs_in),		//horizontal synchronisation in
	._vsync_in(vs_in),		//vertical synchronisation in
	._csync_in(1'b1),		//composite synchronization in, only used if dblscan==0
	.red_out(r), 		        //red componenent video out
	.green_out(g),  	        //green component video out
	.blue_out(b),		        //blue component video out
	._hsync_out(hs),		//horizontal synchronisation out
	._vsync_out(vs)			//vertical synchronisation out
 );
    
endmodule
