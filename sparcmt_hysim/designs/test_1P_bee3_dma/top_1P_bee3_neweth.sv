//-------------------------------------------------------------------------------------------------  
// File:        top_1P_bee3_neweth.sv
// Author:      Zhangxi Tan 
// Description: Top level design for one pipeline and BEE3 dram controller with the new ethernet
//-------------------------------------------------------------------------------------------------

`timescale 1ns / 1ps

`ifndef SYNP94
import libconf::*;
import libopcodes::*;
import libiu::*;
import libxalu::*;
import libmmu::*;
import libcache::*;
import libmemif::*;
import libio::*;
import libdebug::*;
import libtm::*;
import libtech::*;
import libeth::*;
import libperfctr::*;
`else
`include "../../lib/cpu/libiu.sv"
`include "../../lib/cpu/libmmu.sv"
`include "../../lib/cpu/libcache.sv"
`include "../../lib/cpu/libxalu.sv"
`include "../../lib/mem/libmemif.sv"
`include "../../lib/io/libio.sv"
`include "../../lib/tm/libtm.sv"
`include "../../lib/eth/libeth.sv"
`include "../../lib/tm/perfctr/libperfctr.sv"
`endif



module flight_recorder #(parameter DWIDTH=72) (input bit clk, input bit rst,        
             input bit  [DWIDTH-1:0] din, 
             output bit [DWIDTH-1:0] dout) /* synthesis syn_hier="hard" */;

  bit             start_read;
  bit [DWIDTH/36 :0]      full;
  bit [(DWIDTH/36+1)*36-1 :0] din_fx, dout_fx;
  
  always_comb begin
    din_fx = '0;
    din_fx[DWIDTH-1:0] = din;
    dout = dout_fx[DWIDTH-1:0];
  end
  
  always_ff @(posedge clk) begin
    if (rst)
      start_read <= '0;
    else      
      start_read <= (start_read == 0) ? full[0] : '1; 
  end
  
  generate 
    genvar i;
    
    for (i=0;i<DWIDTH/36 + 1;i++) begin
          FIFO36 #(
        .ALMOST_FULL_OFFSET(1022),
        .DATA_WIDTH(36),
        .DO_REG(1),
        .EN_SYN("TRUE"),
        .FIRST_WORD_FALL_THROUGH("FALSE")
      ) fr_fifo (
        .ALMOSTEMPTY(),
        .ALMOSTFULL(full[i]),
        .DO(dout_fx[i*36 +: 32]),
        .DOP(dout_fx[i*36+32 +: 4]),
        .EMPTY(),
        .FULL(),
        .RDCOUNT(),
        .RDERR(),
        .WRCOUNT(),
        .WRERR(),
        .DI(din_fx[i*36 +: 32]),
        .DIP(din_fx[i*36+32 +: 4]),
        .RDCLK(clk),
        .RDEN(start_read),
        .RST(rst),
        .WRCLK(clk),
        .WREN(~rst)
      );      
    end   
  endgenerate
  
endmodule

module fpga_top(input bit clkin_p, input bit clkin_n, input bit clk200_p, input bit clk200_n, input bit rstin, input bit cpurst, //output bit done_led, output bit error_led,
  //rs232 signals
  input     bit     RxD,
  output    bit     TxD,
  //SODIMM signals
  inout  [63:0]              ddr2_dq,
  output [13:0]              ddr2_a,
  output [2:0]               ddr2_ba,
  output                     ddr2_ras_n,
  output                     ddr2_cas_n,
  output                     ddr2_we_n,
  output [1:0]               ddr2_cs_n,
  output [1:0]               ddr2_odt,
  output [1:0]               ddr2_cke,
  output [7:0]               ddr2_dm,
  inout  [7:0]               ddr2_dqs,
  inout  [7:0]               ddr2_dqs_n,
  output [1:0]               ddr2_ck,
  output [1:0]               ddr2_ck_n,
  // Error LEDs
  output bit error1_led,
  output bit error2_led,
  //Ethernet signals
  output bit [7:0] PHY_TXD,
  output bit PHY_TXEN,
  output bit PHY_TXER,
  output bit PHY_GTXCLK,
  input bit [7:0] PHY_RXD,
  input bit PHY_RXDV,
  input bit PHY_RXER,
  input bit PHY_RXCLK,
//  input bit PHY_TXCLK,
//  input bit PHY_COL,
//  input bit PHY_CRS,
  output bit PHY_RESET,

  //PCIE interface
  output  bit [(1 - 1):0] pci_exp_txp,
  output  bit [(1 - 1):0] pci_exp_txn,
  input   bit [(1 - 1):0] pci_exp_rxp,
  input   bit [(1 - 1):0] pci_exp_rxn,

  // System (SYS) Interface

  input   bit    sys_clk_p,
  input   bit    sys_clk_n,
  input   bit    sys_reset_n,
  output  bit    refclkout
);
  iu_clk_type gclk;            //global clock and clock enable
  bit          rst;             //reset
  
  bit		   eth_rst;
  
//  io_bus_out_type io_in;

  //dma buffer master interface
  debug_dma_read_buffer_in_type   eth_rb_in;
  debug_dma_write_buffer_in_type  eth_wb_in;    //no use currently
  debug_dma_write_buffer_out_type eth_wb_out;   //no use currently        

  //dma buffer slave interface
  debug_dma_read_buffer_in_type   dma_rb_in;
  debug_dma_read_buffer_out_type  dma_rb_out;
  debug_dma_write_buffer_in_type  dma_wb_in;

  //dma command interface 
  debug_dma_cmdif_in_type         dma_cmd_in;     //cmd input 
  //bit                             dma_cmd_ack;    //cmd has been accepted
  //dma status from IU
  bit                             dma_done;
  
  //dma timing model interface
  dma_tm_ctrl_type                dma2tm;

  //mem loopback interface
  bit [127:0]			tm_data_to_host;
  tm_cpu_ctrl_token_type	tm_data_from_cpu;
  bit [31:0]			tm_data_to_cpu;
  bit				mem_data_out_valid;
  bit valid_out, mem_cnt_eq;//replay;

  bit ldst_out;

  //speedtm interface with eth
  bit [42:0]			eth2speedtm;
  bit				speedtm_running;
  
  //ethernet
  bit eth_tm_reset, cpu_reset;
  bit clk_p;  
  
  bit cpu_seu;
  
  //dram clk related signals
  dram_clk_type                   ram_clk;
  bit                             dramrst;
  bit							  clk200, clk200x;
  bit							  dramfifo_error;
//  (* syn_srlstyle = "registers" *) bit [3:0]						  dramfifo_error_pipe;
  //memory controller interface
  mem_controller_interface        mcif(gclk, rst);
  
  assign cpu_reset = eth_tm_reset | cpurst;

//  assign io_in = '{default:0};
  
  //------------------generate clock and reset---------------------- 
  clk_inb #(.differential(0)) gen_clkin (.clk_p(clkin_p), .clk_n(clkin_n),.clk(clk_p));
  clk_inb #(.differential(1)) gen_clk200 (.clk_p(clk200_p), .clk_n(clk200_n), .clk(clk200x));
  
  gated_clkbuf gen_clk200_buf(.clk_in(clk200x), .clk_out(clk200), .clk_ce(1'b1));
  IBUF sys_reset_n_ibuf_top (.O(sys_reset_n_c), .I(sys_reset_n));
  
  clkrst_gen_2 #(.differential(0), .IMPL_IBUFG(0), .BOARDSEL(0), .nocebuf(1)) gen_gclk_rst(.*, .clk200, .rstin(~rstin), .dramrst(~dramrst), .clkin_p(clk_p), .cpurst(cpu_reset), .clkin_b());


  //generate cpu 
  cpu_top_dma   gen_cpu(.gclk, .rst, 
//        .io_in,
//        .io_out(),
        .luterr(),
        .bramerr(),
        .sb_ecc(),
        .dma_rb_in,
        .dma_rb_out,
        .dma_wb_in,
        .dma_cmd_in,     //cmd input 
        .dma_cmd_ack(),    //cmd has been accepted
        .dma_done,
        .dma2tm,
        .mcif,
        .error1_led,
        .error2_led(cpu_seu),
	.tm_pkt_in(tm_data_to_cpu),//mem data from host
	.tm_pkt_out(tm_data_to_host), //mem data out to host
        .tm_pkt_valid(mem_data_out_valid),
        .eth_mem_rd(eth_mem_rd),
	.valid_out(valid_out),
	.speedtm_running(speedtm_running),
    	.eth2speedtm(eth2speedtm),
	.mem_cnt_eq(mem_cnt_eq),
	.ldst_out(ldst_out),
        //PCIE interface
        .pci_exp_txp(pci_exp_txp),
        .pci_exp_txn(pci_exp_txn),
        .pci_exp_rxp(pci_exp_rxp),
        .pci_exp_rxn(pci_exp_rxn),

  // System (SYS) Interface

        .sys_clk_p(sys_clk_p),
        .sys_clk_n(sys_clk_n),
        .sys_reset_n(sys_reset_n_c),
        .refclkout(refclkout)
        );
  //assign tm_data_to_host = {tm_data_from_cpu.tid, tm_data_from_cpu.valid, tm_data_from_cpu.run, tm_data_from_cpu.replay, tm_data_from_cpu.retired, 1'b0,  tm_data_from_cpu.inst, tm_data_from_cpu.paddr, tm_data_from_cpu.npc};

/*
   always_ff @(posedge gclk.clk2x or posedge rst) begin
		if (rst)
			error2_led <= '0;
		else if (dramfifo_error_pipe[3])
			error2_led <= '1;
   end

   always_ff @(posedge gclk.clk2x) dramfifo_error_pipe <= {dramfifo_error_pipe[2:0], dramfifo_error}; */


  `ifdef MAGIC_MEM
    sim_memctrl #(.MEMSIZE(1024*1024*16)) gen_memsim (
      .rst,
      .user_if(mcif)
    );
  `else
  dramctrl_bee3_ml505 #(
  `ifdef MODEL_TECH
  .REFRESHINHIBIT(1'b1)
  `else
  .REFRESHINHIBIT(1'b0)
  `endif
  ,
  .no_ecc_data_path("FALSE")
  )
  
                    gen_bee3mem(
                         .ram_clk,   //dram clock
                         .user_if(mcif),
                         //Signals to SODIMM
                          .DQ(ddr2_dq),   //the 64 DQ pins
                          .DQS(ddr2_dqs), //the 8  DQS pins
                          .DQS_L(ddr2_dqs_n),
                          .DIMMCK(ddr2_ck),  //differential clock to the DIMM
                          .DIMMCKL(ddr2_ck_n),
                          .A(ddr2_a),   //addresses to DIMMs
                          .BA(ddr2_ba),   //bank address to DIMMs
                          .RAS(ddr2_ras_n),
                          .CAS(ddr2_cas_n),
                          .WE(ddr2_we_n),
                          .ODT(ddr2_odt),
                          .ClkEn(ddr2_cke), //common clock enable for both DIMMs. SSTL1_8
                          .RS(ddr2_cs_n),
                          .DM(ddr2_dm),
 
                          .TxD(TxD),                //RS232 transmit data
                          .RxD(RxD),                //RS232 received data
                          .SingleError(dramfifo_error),         //Unconnected right now
                          .DoubleError()          //Double errors

       ); 

   `endif
    
    //generate Ethnet DMA and the debug ring
    eth_rx_pipe_data_type   rx_pipe[0:1];
    eth_tx_ring_data_type   tx_ring[0:2];

    bit                     dma_buf_sberr, dma_buf_dberr /*, dma_buf_seu*/;
    
              
    eth_dma_controller   gen_eth_dma_master(    
            //clock
            .reset(~rstin),         //global reset input
            .clkin(clk_p),          //global clock input (used to generate the 125 MHz tx clock)
            .clk200,                //200 MHz reference clock for IDELAYCTRL    
            .gclk, 
            .eth_rst,
        
            //ring interface             
            .rx_pipe_out(rx_pipe[0]),        
            .tx_ring_in(tx_ring[2]),
            .tx_ring_out(tx_ring[0]),
                        
            // GMII Interface (1000 Base-T PHY interface)
            .GMII_TXD(PHY_TXD),
            .GMII_TX_EN(PHY_TXEN),
            .GMII_TX_ER(PHY_TXER),
            .GMII_TX_CLK(PHY_GTXCLK), //to PHY. Made in ODDR
            .GMII_RXD(PHY_RXD),
            .GMII_RX_DV(PHY_RXDV),
            .GMII_RX_ER(PHY_RXER),
            .GMII_RX_CLK(PHY_RXCLK), //from PHY. Goes through BUFG
            .GMII_RESET_B(PHY_RESET)              
        );
                
    //tm controll
    eth_tm_control    gen_tm_control(
            .clk(gclk.clk),
            .reset(eth_rst),
            //rx pipe
            .rx_pipe_in(rx_pipe[0]),                                                
            .rx_pipe_out(rx_pipe[1]),
            //tx ring interface
            .tx_ring_in(tx_ring[0]),
            .tx_ring_out(tx_ring[1]),
    
            //timing model interface
            .dma2tm,
            .cpurst(eth_tm_reset)
            );

    //cpu control
    eth_cpu_control #(.mypid(8'b0)) gen_cpu_control(
            .clk(gclk.clk),
            .reset(eth_rst),
            .gclk,
            //rx pipe
            .rx_pipe_in(rx_pipe[1]),                                                
            .rx_pipe_out(),
            //tx ring interface
            .tx_ring_in(tx_ring[1]),
            .tx_ring_out(tx_ring[2]),

	    //mem interface
	    .mem_data_out(tm_data_to_cpu), //output of mem data from host for tm
	    .mem_data_in(tm_data_to_host), //input mem data to go into tx ring for eth output to host
	    .mem_data_out_valid(mem_data_out_valid), //is the received data valid - output
    
            //cpu dma interface
            .dma_cmd_in,//cmd input 
            .dma_done,		//dma status      
            
            //cpu dma buffer interface
            .dma_rb_in,
            .dma_rb_out,
            .dma_wb_in,
            .sberr(dma_buf_sberr),               
            .dberr(dma_buf_dberr),
            .luterr(),
	    .poll_not_ready(tm_data_to_host[98]),//location of the replay bit for the output register
            .eth_mem_rd(eth_mem_rd),
	    .valid_out(valid_out),
	    .speedtm_running(speedtm_running),
            .eth2speedtm(eth2speedtm),
	    .mem_cnt_eq(mem_cnt_eq)
            );
                
    always_ff @(posedge gclk.clk2x) begin
/*      if (eth_rst)
        dma_buf_seu <= '0;
      else
        dma_buf_seu <= dma_buf_seu | dma_buf_sberr | dma_buf_dberr;*/   //forget about dma seu for now
        
      error2_led <= cpu_seu /*| dma_buf_seu*/;
    end
    
    
endmodule

module perfctr_host_counter(input iu_clk_type gclk, input bit rst, 
                  output io_bus_out_type      bus_out,
                  input  io_bus_in_type       bus_in,
                  //counter signals
                  input  bit                  hostcycle,
                  input  bit                  icmiss,
                  input  bit                  ldmiss,
                  input  bit                  stmiss,
                  input  bit                  nretired,
                  input  bit                  ldst,
                  input  bit          blkcnt,
                  input  bit          rawcnt,
                  input  bit          replay,
                  input  bit            microcode,
                  input  bit          idlecnt,
                  input  bit          replayfpu,
                  input  bit          replaymul
                  );
  

perfctr_ring_ctrl_type  ring_ctrl_input[0:13];
perfctr_ring_data_type  ring_data_input[0:13];

perfctr_ring_buf_type   read_data;

//input registers
bit [NTHREADIDMSB:0]  rtid;    //thread id
bit [IO_AWIDTH-1:0]   raddr;    //request address

always_ff @(posedge gclk.clk) begin
  rtid  <= bus_in.tid;
  raddr <= bus_in.addr;
end

always_comb begin
  ring_ctrl_input[0].tid  = rtid;
  ring_ctrl_input[0].addr = unsigned'(raddr[3 +: 4]);   //request address   
  ring_ctrl_input[0].valid = bus_in.en & ~bus_in.replay & ~bus_in.rw & ~raddr[2];
  
  ring_data_input[0] = '0;

  //output
  bus_out.irl    = '0;
//  bus_out.rdata  = (raddr[2]) ? read_data.data[63:32] : read_data.data[31:0];
  bus_out.rdata  = (raddr[2]) ? read_data.data[31:0] : read_data.data[63:32];
  bus_out.retry  = bus_in.en & (~bus_in.replay | ~read_data.valid) & ~bus_in.rw & (~raddr[2] | ~read_data.valid);
//  bus_out.retry = ring_ctrl_input[0].valid | ~read_data.valid;
end


perfctr_reg #(.IOADDR(0)) hostcycle_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[0]),
                                        .ring_data_in(ring_data_input[0]),
                                        .ring_ctrl_out(ring_ctrl_input[1]),
                                        .ring_data_out(ring_data_input[1]),
                                        .increment_en(hostcycle));     

perfctr_reg #(.IOADDR(1)) icmiss_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[1]),
                                        .ring_data_in(ring_data_input[1]),
                                        .ring_ctrl_out(ring_ctrl_input[2]),
                                        .ring_data_out(ring_data_input[2]),
                                        .increment_en(icmiss));     

perfctr_reg #(.IOADDR(2)) ldmiss_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[2]),
                                        .ring_data_in(ring_data_input[2]),
                                        .ring_ctrl_out(ring_ctrl_input[3]),
                                        .ring_data_out(ring_data_input[3]),
                                        .increment_en(ldmiss));     

perfctr_reg #(.IOADDR(3)) stmiss_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[3]),
                                        .ring_data_in(ring_data_input[3]),
                                        .ring_ctrl_out(ring_ctrl_input[4]),
                                        .ring_data_out(ring_data_input[4]),
                                        .increment_en(stmiss));     

perfctr_reg #(.IOADDR(4)) nretired_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[4]),
                                        .ring_data_in(ring_data_input[4]),
                                        .ring_ctrl_out(ring_ctrl_input[5]),
                                        .ring_data_out(ring_data_input[5]),
                                        .increment_en(nretired));     

perfctr_reg #(.IOADDR(5)) ldst_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[5]),
                                        .ring_data_in(ring_data_input[5]),
                                        .ring_ctrl_out(ring_ctrl_input[6]),
                                        .ring_data_out(ring_data_input[6]),
                                        .increment_en(ldst));     

perfctr_reg #(.IOADDR(6)) blkcnt_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[6]),
                                        .ring_data_in(ring_data_input[6]),
                                        .ring_ctrl_out(ring_ctrl_input[7]),
                                        .ring_data_out(ring_data_input[7]),
                                        .increment_en(blkcnt));     


perfctr_reg #(.IOADDR(7)) rawcnt_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[7]),
                                        .ring_data_in(ring_data_input[7]),
                                        .ring_ctrl_out(ring_ctrl_input[8]),
                                        .ring_data_out(ring_data_input[8]),
                                        .increment_en(rawcnt));     

perfctr_reg #(.IOADDR(8)) replay_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[8]),
                                        .ring_data_in(ring_data_input[8]),
                                        .ring_ctrl_out(ring_ctrl_input[9]),
                                        .ring_data_out(ring_data_input[9]),
                                        .increment_en(replay));     
                                        

perfctr_reg #(.IOADDR(9)) microcode_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[9]),
                                        .ring_data_in(ring_data_input[9]),
                                        .ring_ctrl_out(ring_ctrl_input[10]),
                                        .ring_data_out(ring_data_input[10]),
                                        .increment_en(microcode));     
                                        

perfctr_reg #(.IOADDR(10)) idlecnt_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[10]),
                                        .ring_data_in(ring_data_input[10]),
                                        .ring_ctrl_out(ring_ctrl_input[11]),
                                        .ring_data_out(ring_data_input[11]),
                                        .increment_en(idlecnt));     

perfctr_reg #(.IOADDR(11)) replayfpu_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[11]),
                                        .ring_data_in(ring_data_input[11]),
                                        .ring_ctrl_out(ring_ctrl_input[12]),
                                        .ring_data_out(ring_data_input[12]),
                                        .increment_en(replayfpu));     

perfctr_reg #(.IOADDR(12)) replaymul_ctr(.gclk, .rst,
                                        .ring_ctrl_in(ring_ctrl_input[12]),
                                        .ring_data_in(ring_data_input[12]),
                                        .ring_ctrl_out(ring_ctrl_input[13]),
                                        .ring_data_out(ring_data_input[13]),
                                        .increment_en(replaymul));     


perfctr_output_buf  outbuf(.gclk, .rst, 
               .ring_ctrl_in(ring_ctrl_input[13]),
               .ring_data_in(ring_data_input[13]),
               .io_tid(rtid),
               .io_we(ring_ctrl_input[0].valid),
               .read_data(read_data)
               );

endmodule

module cpu_top_dma(input iu_clk_type gclk, input bit rst,
    //IO interface
//    input  io_bus_out_type      io_in,
//    output io_bus_in_type       io_out,
   
    //dma buffer interface
    output debug_dma_read_buffer_in_type   dma_rb_in,
    input  debug_dma_read_buffer_out_type  dma_rb_out,
    output debug_dma_write_buffer_in_type  dma_wb_in,
    //dma command interface 
    input  debug_dma_cmdif_in_type         dma_cmd_in,     //cmd input 
    output bit                             dma_cmd_ack,    //cmd has been accepted
    //dma timing model interface
    input  dma_tm_ctrl_type                dma2tm,

    //memory controller interface
    mem_controller_interface.cpu           mcif,

    //dma status
    output bit                             dma_done,
    output bit           error1_led,
    output bit           error2_led,
//    output bit                             done_led,  
//    output bit                             error_led,
    output  bit                                luterr, 
    output  bit                                bramerr, 
    output  bit                               sb_ecc,  //interface to xalu
    input   bit [31:0]       tm_pkt_in,
    output  bit [127:0]      tm_pkt_out, //tm_cpu_ctrl_token_type
    input   bit		      tm_pkt_valid,
    input   bit		      eth_mem_rd,
    output  bit		     valid_out,
    output  bit		     speedtm_running,
    input   bit [42:0]       eth2speedtm,
    output  bit             mem_cnt_eq,
    output  bit	            mem_out_empty,
    output  LDST_CTRL_TYPE    ldst_out,

    //PCIE interface
    output  bit [(1 - 1):0] pci_exp_txp,
    output  bit [(1 - 1):0] pci_exp_txn,
    input   bit [(1 - 1):0] pci_exp_rxp,
    input   bit [(1 - 1):0] pci_exp_rxn,

                        // System (SYS) Interface

    input   bit    sys_clk_p,
    input   bit    sys_clk_n,
    input   bit    sys_reset_n,
    output  bit    refclkout
    );

  bit [15:0]      pc_count;
  bit             count_state;          
  bit       xc_error_mode, xc_error_r, xc_error_out;

// FPGA interface
  bit [10:0] rd_addr_fpga;
  bit [3:0]  rd_be_fpga;
  bit [31:0] rd_data_fpga;

  bit [10:0] wr_addr_fpga;
  bit [7:0]  wr_be_fpga;
  bit [127:0] wr_data_fpga;
  bit        wr_en_fpga;
  bit        wr_busy_fpga;
  
  
  const bit [31:0]    stopct_pc = 32'h2734;
  const bit [31:0]    error_pc  = 32'h1220;
    

  
  //----------wires----------
  //pipeline registers
  commit_reg_type   comr;   //WB -> IF, WB -> REG
  decode_reg_type   der;      //IF -> DE
  reg_reg_type       regr;    //DE -> REG
  ex_reg_type       exr;      //REG -> EX
  mem_reg_type       memr;    //EX -> MEM
  xc_reg_type        xcr;     //MEM -> XC

  //immu
  immu_iu_in_type   immu_if_in;    //IF -> IMMU
  immu_iu_out_type  immu_de_out;    //IMMU -> DE
  
  //dmmu
  mmu_iu_dtlb_type       ex2mem_dmmu;    //input from ex1 stage to mmu, EX->MEM
  mmu_host_cache_in_type mmu2hc;         //output from dmmu @EX2/MEM1, DMMU->MEM
  bit			                 mmu2hc_invalid;

  dmmu_if_iu_in_type    iu2dmmu;    //IU -> DMMU
  dmmu_iu_out_type  dmmu2iu;    //DMMU -> IU
  

	mmu_mmumem_itlb_type dmmu2immu; //DMMU->IMMU
	
	bit                  itlb_miss, dtlb_miss;

  //I$
  icache_if_in_type    icache_if_in;          //IF -> I$
  icache_data_out_type  icache_if_out;         //I$ -> IF
  cache2iu_ctrl_type    icache_de_out;         //I$ -> DE
  icache_de_in_type    icache_de_in;          //IMMU->I$

  mem_stat_out_type    icache_mem2iu_stat;  //memory status -> I$
  bit [NTHREADIDMSB:0]  icache_iu2mem_tid;    //I$ -> memory ctrl
  mem_cmd_in_type       icache_iu2mem_cmd;    //I$ -> memory ctrl 
  
  cache_ram_in_type    icache_mem2cacheram; //mem -> I$ ram
  cache_ram_out_type    icache_cacheram2mem;  //I$ ram -> mem
  
  //D$
  dcache_data_out_type  dcache_data;          //D$ -> IU
  dcache_iu_in_type    iu2dcache;            //IU -> D$ 
//  dcache_mmu_in_type    dmmu2cache;           //DMMU->D$
  mmu_host_cache_out_type dcache2mmu;          // D$ -> DMMu
  cache2iu_ctrl_type    dcache2iu;             //D$ -> IU control

  mem_stat_out_type    dcache_mem2iu_stat;   //memory status -> D$
  bit [NTHREADIDMSB:0]  dcache_iu2mem_tid;    //D$ -> memory ctrl
  mem_cmd_in_type       dcache_iu2mem_cmd;    //D$ -> memory ctrl

  cache_ram_in_type    dcache_mem2cacheram; //mem -> D$ ram
  cache_ram_out_type    dcache_cacheram2mem;  //D$ ram -> mem

  //mem interface
  mem_ctrl_in_type      imem_in[0:0];
  mem_ctrl_in_type      dmem_in[0:0];
  mem_ctrl_out_type    imem_out[0:0];
  mem_ctrl_out_type    dmem_out[0:0];

  //dma_interface
  debug_dma_in_type     iu2dma;
  debug_dma_out_type    dma2iu;
  bit [NTHREADIDMSB:0]    dma_rtid;   //(IU) read DMA register
  
  //timing model interface
  tm_cpu_ctrl_token_type cpu2tm_out;
  bit [127:0]		 replay_out; //altered for loopback
  tm_dbg_ctrl_type       dma2cpu;     //start and stop everything right now
  tm2cpu_token_type      tm2cpu, tm2cpu_final, tm2cpu_tm;
  tm2cpu_token_type r_tm2cpu, v_tm2cpu;
  bit [NTHREADIDMSB:0] tm2cpu_tid_inc;
  bit running, tick, replay_empty, replay_full, replay_data_rdy, replay_data_read;
  bit mem_out_full;
  bit speedtm_done;

   //primitives version
bit [31:0] replay_out_short, ethtm2cpu;
bit [63:0] tm_pkt_out_1, tm_pkt_out_2;
bit mem_in_re_delay, v_mem_in_re_delay, v_replay_re_delay;
bit [15:0] wrcount_memin, wrcount_memout;
bit [7:0] v_tid;

bit [31:0] pcie2fpga;
bit pcie2fpga_valid;

bit [127:0] pcie2host;

pcie_interface pcie_interface( // to pcie_interface type and change ports accordingly
                        // PCI Express Fabric Interface

                        .pci_exp_txp(pci_exp_txp),
                        .pci_exp_txn(pci_exp_txn),
                        .pci_exp_rxp(pci_exp_rxp),
                        .pci_exp_rxn(pci_exp_rxn),

                        // System (SYS) Interface

                        .sys_clk_p(sys_clk_p),
                        .sys_clk_n(sys_clk_n),
                        .sys_reset_n(sys_reset_n),

						.clk(gclk.clk),

                        // TM2CPU interface
                        .pcie_data_in(pcie2fpga),		//out  [31:0]
                        .pcie_data_in_valid(pcie2fpga_valid),	//out  bit

                        .pcie_data_out(pcie2host),			//in [127:0]
                        .mem_cnt_eq(mem_cnt_eq),		//in bit
			.mem_out_empty(mem_out_empty),		//in bit
			.wr_ready(pcie_wr_rdy)
                        );

assign pcie2host = 128'hFFFFE03FFFFFFFFFFFFFFFFFFFFFFFFF;//tm_pkt_out;

FIFO36 #(
  .DATA_WIDTH(36) //set to 36 for data and parity - default is 4...
  ) mem_in_queue
  (
     .DO(ethtm2cpu), //data out - replace tm_pkt_in refs with references to this and using empty signal - watch out for single cycle delay after RD_en asserted
     //.DOP(), //data out parity
     .FULL(mem_in_full), //full
     .EMPTY(mem_in_empty), //empty
     .DI(pcie2fpga),//tm_pkt_in), //data in - port from eth_cpu_control
     .DIP(8'b0), //data in parity
     .WREN(pcie2fpga_valid&pcie2fpga[1]),//tm_pkt_valid&tm_pkt_in[1]), //wr en - tm_pkt_valid & valid bit set in the pkt
     .RDEN(~mem_in_empty), //rd en
     .RDCLK(gclk.clk),
     .WRCLK(gclk.clk),
     .RST(rst), //reset
     .WRCOUNT(wrcount_memin)
  );

FIFO36 #(
  .DATA_WIDTH(36) //set to 36 for data and parity - default is 4...
  ) replay_queue
  (
     .DO(replay_out_short), //data out
     //.DOP(), //data out parity
     .FULL(replay_full), //full
     .EMPTY(replay_empty), //empty
     .DI({20'b0,cpu2tm_out.tid, cpu2tm_out.valid, cpu2tm_out.run, cpu2tm_out.replay, cpu2tm_out.retired, 1'b0}), //data in
     .DIP(8'b0), //data in parity
     .WREN(cpu2tm_out.replay&~speedtm_running), //wr en
     .RDEN((mem_in_empty & ~replay_empty)), //rd en - old: ~tm_pkt_valid&~replay_empty
     .RDCLK(gclk.clk),
     .WRCLK(gclk.clk),
     .RST(rst) //reset
  );

  //assign replay_out = {replay_out_short, 96'b0};
  assign valid_out = ~mem_out_empty;
  assign mem_cnt_eq = (wrcount_memin[8:0] == wrcount_memout[8:0]);

FIFO36_72 mem_out_queue1
  (
     .DO(tm_pkt_out_1), //data out
     //.DOP(), //data out parity
     .FULL(mem_out_full), //full
     .EMPTY(mem_out_empty), //empty
     .DI({19'b0,cpu2tm_out.tid, cpu2tm_out.valid, cpu2tm_out.run, cpu2tm_out.replay, cpu2tm_out.retired, ldst_out, cpu2tm_out.inst}), //data in
     .DIP(8'b0), //data in parity
     .WREN((cpu2tm_out.valid)&~speedtm_running), //wr en - |cpu2tm_out.replay
     .RDEN(eth_mem_rd), //rd en  (eth_mem_rd&~mem_out_empty)
     .RDCLK(gclk.clk),
     .WRCLK(gclk.clk),
     .RST(rst), //reset
     .WRCOUNT(wrcount_memout)
  );

FIFO36_72 mem_out_queue2
  (
     .DO(tm_pkt_out_2), //data out
     //.DOP(), //data out parity
     //.FULL(replay_full), //full
     //.EMPTY(replay_empty), //empty
     .DI({cpu2tm_out.paddr, cpu2tm_out.npc}), //data in
     .DIP(8'b0), //data in parity
     .WREN((cpu2tm_out.valid)&~speedtm_running), //wr en - |cpu2tm_out.replay
     .RDEN(eth_mem_rd), //rd en (eth_mem_rd&~mem_out_empty)
     .RDCLK(gclk.clk),
     .WRCLK(gclk.clk),
     .RST(rst) //reset
  );
  assign tm_pkt_out = {tm_pkt_out_1, tm_pkt_out_2};

  //logic to swap between mem raw data and tm interface
  assign tm2cpu.running = tm2cpu.valid;
  assign v_tm2cpu.valid = ethtm2cpu[1] & mem_in_re_delay; //only pass valid bit if the packet is valid at that point (controls timing of the tm)
  assign v_tm2cpu.run = ethtm2cpu[2] & mem_in_re_delay;//tm_pkt_in[2]&tm_pkt_valid;
  assign running = tm2cpu.running;//tm_pkt_in[0];
  assign tick = tm2cpu.valid & tm2cpu.run & (tm2cpu.tid == 0);
  assign tm2cpu_tid_inc = tm2cpu_tm.valid ? tm2cpu.tid : tm2cpu.tid+1; //if speed tm running, use that, otherwise increment for memops
  assign v_tid = ethtm2cpu[NTHREADIDMSB+3:3];//tm_pkt_in[NTHREADIDMSB+3:3];
  //assign v_mem_in_re_delay = ~mem_in_empty;
  
  always @(*) begin
	casex({speedtm_running, ~replay_empty,~mem_in_empty}) //logic for choosing the correct packet; casex means x = don't care
	3'b000: begin
		tm2cpu_final = tm2cpu;
		replay_data_read =1'b0;
	       end
	3'b001: begin
		tm2cpu_final = tm2cpu;
		replay_data_read =1'b0;
	       end
	3'b010: begin 
		/**tm2cpu_final.tid = replay_out_short[13:5];
		tm2cpu_final.valid = 1'b1;
		tm2cpu_final.run = 1'b1;
		tm2cpu_final.running = 1'b1;**/
                //replay_data_read =1'b1;

		tm2cpu_final = tm2cpu;
		replay_data_read =1'b0;
		end
	3'b011: begin
		tm2cpu_final = tm2cpu;
		replay_data_read =1'b0;
	       end
	3'b1xx: begin //ignore both replay and mem in since I am running on speedtm
		/**if (tm2cpu_tm.valid) begin
			tm2cpu_final = tm2cpu_tm; //if valid then run speedtm output
		end
		else begin
			tm2cpu_final = tm2cpu; //run DMA instructions in null time
		end**/
		tm2cpu_final = tm2cpu_tm;
		replay_data_read =1'b0;
	       end
	default: begin
		tm2cpu_final = tm2cpu;
		replay_data_read =1'b0;
	       end
	endcase
  end

  //needed for some signal timing and registering
  always_ff@(posedge gclk.clk) begin

     replay_data_rdy <= 1'b0;
     if (v_mem_in_re_delay) begin //if mem in queue is not empty
	   tm2cpu.run <= ethtm2cpu[2]; //use data from cpu
	   tm2cpu.valid <= ethtm2cpu[1];
	   tm2cpu.tid <= ethtm2cpu[NTHREADIDMSB+3:3];
     end
     else if(v_replay_re_delay) begin //else if replay is not empty
           tm2cpu.run <= 1'b1; //use replay info
	   tm2cpu.valid <= 1'b1;
	   tm2cpu.tid <= replay_out_short[13:5];
     end
     else begin
           tm2cpu.run <= 1'b0; //else cycle through TIDs for mem ops (also is speed tm input if valid)
	   tm2cpu.valid <= 1'b0;
	   tm2cpu.tid <= tm2cpu_tid_inc;
     end

     v_replay_re_delay <= ~replay_empty;
     v_mem_in_re_delay <= ~mem_in_empty;
     mem_in_re_delay <= v_mem_in_re_delay;

     /**if (rst) begin
	mem_in_re_delay <= 1'b0;
     end
     else begin
        mem_in_re_delay <= v_mem_in_re_delay & ~mem_in_re_delay;//need to delay RE signal by 1 to know when data out is good
     end**/

     /**if (v_tm2cpu.run & ~r_tm2cpu.run & v_tm2cpu.valid & ~r_tm2cpu.valid)
     	r_tm2cpu.tid <= v_tm2cpu.tid;
     else
	r_tm2cpu.tid <= tm2cpu_tid_inc;**/
     /**if (rst) begin //old tm_pkt_out logic
	tm_pkt_out = 128'h0;
     end
     else if (cpu2tm_out.valid||(cpu2tm_out.replay&cpu2tm_out.run)) begin
  	tm_pkt_out = {cpu2tm_out.tid, cpu2tm_out.valid, cpu2tm_out.run, cpu2tm_out.replay, cpu2tm_out.retired, 1'b0,  cpu2tm_out.inst, cpu2tm_out.paddr, cpu2tm_out.npc};//27'h0,1'b1,1'b1,1'b0,1'b1,1'b0,32'h000000001, 32'h00001111, 32'h0000000C};//27'h7FFFFFF
     end**/
  end

  speed_tm checkpt_tm( //speeds up certain areas so long as you know the instruction address you want to run to
     .gclk(gclk),
     .rst(rst),
     .eth2speedtm(eth2speedtm),//input from eth that has [num cores(10b),valid(1b), instruction address to run to(32b)]
     .cpu2tm(cpu2tm_out), //input
     .tm2cpu(tm2cpu_tm), //output
     .running(speedtm_running), //indicates running or not
     .done(speedtm_done) //single pulse when done
  );

  //io bus connected to timing model
  io_bus_out_type      io_in;
  io_bus_in_type       io_out;
  
  io_bus_out_type      irq_io_out, tm_io_out;
  //bit                  running;
  
  bit                  irqack;
  bit                  irq_timer;
  //bit                  tick;
  
  //-------------------------SEU errors---------------------------
  //lutram errors
  bit [9:0] luterr_r;
  bit   if_lutram_err;          //IF lutram error
  bit   de_lutram_err;          //DE lutram error
  bit   ex_lutram_err;          //EX lutram error
  bit   xc_lutram_err;          //XC lutram error
  bit   imem_if_lutram_err;   //imem if lutram error
  bit   dmem_if_lutram_err;   //imem if lutram error
  bit   dma_luterr;            //DMA register lutram error
  bit   dramctrl_lutram_err; //DRAM controller lut error
  bit   dmmu_lutram_err;      //DMMU lutram error
  bit   immu_lutram_err;      //IMMU lutram error

  //bram errors
  bit [4:0] bramerr_r;
  bit        de_bram_err;     //DE bram error
  bit        ex_bram_err;     //EX bram error
  bit        xc_bram_err;     //XC bram error
  bit        dmmu_dberr, immu_dberr;
  (* syn_srlstyle="registers" *) bit [1:0] r_dmmu_dberr, r_immu_dberr;

//  tlb_error_type  itlb_error, dtlb_error;   //TLB bram parity errors

  //single bit errors corrected by ECC
  bit [3:0] sb_ecc_r;
  bit        de_sb_ecc;       //DE sb error
  bit        xc_sb_ecc;       //XC sb error
  bit 		 dmmu_sberr, immu_sberr;
  (* syn_srlstyle="registers" *) bit [1:0]        r_dmmu_sberr, r_immu_sberr;

  //output registers
  bit        luterr_out;
  bit        bramerr_out;
  bit        sb_ecc_out;
  
  //wire of performance counter
  bit   dcacheblkcnt, dcacherawcnt;
  //performance counter registers
  (* syn_srlstyle="registers" *) bit [1:0]  hostcycle_en;
  (* syn_srlstyle="registers" *) bit [1:0]  icmiss_en;
  (* syn_srlstyle="registers" *) bit [1:0]  ldmiss_en;
  (* syn_srlstyle="registers" *) bit [1:0]  itlbmiss_en;
  (* syn_srlstyle="registers" *) bit [1:0]  dtlbmiss_en;
  (* syn_srlstyle="registers" *) bit [1:0]  stmiss_en;
  (* syn_srlstyle="registers" *) bit [1:0]  nretired_en;
  (* syn_srlstyle="registers" *) bit [1:0]  ldst_en;
  (* syn_srlstyle="registers" *) bit [1:0]  blkcnt_en, rawcnt_en;
  (* syn_srlstyle="registers" *) bit [1:0]  replay_en, idlecnt_en, microcode_en, replaymul_en, replayfpu_en;
  bit   comr_r_run, comr_run, comr_r_dma, comr_dma; 
  bit [11:0] host_global_perf_counter;

  LDST_CTRL_TYPE ldst_out_1, ldst_out_2, ldst_out_3, ldst_out_4;//ldst_out
  
  //flight recorder signals
  /*
  typedef struct packed {
    bit [31:0] inst;
    bit [29:0] pc;
    bit [5:0]  tid;
    bit      ucmode;
    bit      replay;
    bit      run;
    bit      dma_mode;
    bit      error_mode;
    bit      icmiss;
    bit 	    irq;
    bit      mmu_replay;
    bit      dcache_replay;
    bit		    itlbmiss;
    bit      itlbexception;
    bit	     dtlbexception;
    bit		    immu_refill;
  }flight_recorder_data_type;
  bit [127:0]   ic_wdata;
  bit [127:0]   icacheram_dbg_out;
  bit [8:0]   icacheram_read_addr;
  
  immu_data_type	m2_immu_data, xc_immu_data;
      
  localparam FDRWIDTH = $bits(flight_recorder_data_type);
    
  (* syn_preserve=1 *) flight_recorder_data_type fr_din;
  flight_recorder_data_type fr_dout;
  (* syn_noprune=1 *) flight_recorder_data_type  fr_dout_r;
  (* syn_noprune=1 *) bit fdr_trigger;
  (* syn_noprune=1 *) bit[4:0] fdr_trigger_cnt;
*/
  //------------------generate IO bus-------------------------------
  always_comb begin
    io_in = tm_io_out;
    io_in.irl = irq_io_out.irl;
  end

  //------------------generate integer pipeline---------------------
  
  //fetch
  fetch_stage_dma   #(.newsch(1'b1)) gen_if(.*, .luterr(if_lutram_err),.tm2cpu(tm2cpu_final));
  //decode stage
  decode_stage    gen_de(.*, .immu2iu(immu_de_out), .luterr(de_lutram_err), .bramerr(de_bram_err), .sb_ecc(de_sb_ecc));
  //regacc stage
  regacc_stage_dma  gen_regacc(.*);
  //execuation stage
  execution_stage   #(.DOREG(1'b1), .FASTMUL(1'b1)) gen_ex(.*, .luterr(ex_lutram_err), .bramerr(ex_bram_err), .iu2dtlb(ex2mem_dmmu));
  //memory stage
  memory_stage    #(.INREG(1)) gen_mem(.*, .iu2dtlb(ex2mem_dmmu), .mmu2hc);
  //exception stage
  exception_stage_dma gen_xc(.*, .luterr(xc_lutram_err), .bramerr(xc_bram_err), .sb_ecc(xc_sb_ecc), .errmode(xc_error_mode), .irqack(irqack), .cpu2tm(cpu2tm_out));
    
  //------------------generate mmu---------------------
  immu_if  gen_immu(.*, .mem2tlb(dmmu2immu), .sberr(immu_sberr), .dberr(immu_dberr), .luterr(immu_lutram_err));
	dmmu_if  gen_dmmu(.*, .toitlb(dmmu2immu), .mmu2hc,	.hc2mmu(dcache2mmu), .mmu2hc_invalid,	/*.mmu2hcfsm(dmmu2cache),*/ .sberr(dmmu_sberr), .dberr(dmmu_dberr), .luterr(dmmu_lutram_err));

  //------------------generate cache---------------------
  icache    #(.read2x(1), .write2x(1), .NONECCDRAM(`ifdef MAGIC_MEM
                                                    "TRUE"
                                                    `else
                                                     "FALSE"
                                                    `endif
                                                    ))  gen_icache(.gclk, .rst, 
          .mem2iu_stat(icache_mem2iu_stat), 
          .iu2mem_tid(icache_iu2mem_tid),
          .iu2mem_cmd(icache_iu2mem_cmd),
          .mem2cacheram(icache_mem2cacheram), 
          .cacheram2mem(icache_cacheram2mem),
          .iu2cache(icache_if_in),
          .immu2cache(icache_de_in),
//          .cacheram_dbg_out(icacheram_dbg_out),
//          .cacheram_read_addr(icacheram_read_addr),
          .if_out(icache_if_out),
          .de_out(icache_de_out));

  dcache_udc    #(.read2x(1), .write2x(1), .NONECCDRAM(`ifdef MAGIC_MEM
                                                    "TRUE"
                                                    `else
                                                     "FALSE"
                                                    `endif
                                            ))  gen_dcache(.gclk, .rst, 
          .mem2iu_stat(dcache_mem2iu_stat), 
          .iu2mem_tid(dcache_iu2mem_tid),
          .iu2mem_cmd(dcache_iu2mem_cmd),
          .mem2cacheram(dcache_mem2cacheram), 
          .cacheram2mem(dcache_cacheram2mem),
          .iu2cache(iu2dcache),
         // .dmmu2cache(dmmu2cache),
          .data_out(dcache_data),
          .dcache2iu,
	        .dmmu_invalid(mmu2hc_invalid),
          .*);

  //------------------generate memory IF-------------------
  imem_if   #(.read2x(1), .write2x(1))  gen_imem_if(.gclk, .rst,
          .iu2mem_tid(icache_iu2mem_tid),
          .iu2mem_cmd(icache_iu2mem_cmd),
          .mem2iu_stat(icache_mem2iu_stat),
          .cacheram2mem(icache_cacheram2mem),
          .mem2cacheram(icache_mem2cacheram),
          .from_mem(imem_out[0]),
          .to_mem(imem_in[0]),
          .luterr(imem_if_lutram_err));

  dmem_if   #(.read2x(1), .write2x(1), .nonblocking(1)) gen_dmem_if(.gclk, .rst,
          .iu2mem_tid(dcache_iu2mem_tid),
          .iu2mem_cmd(dcache_iu2mem_cmd),
          .mem2iu_stat(dcache_mem2iu_stat),
          .cacheram2mem(dcache_cacheram2mem),
          .mem2cacheram(dcache_mem2cacheram),
          .from_mem(dmem_out[0]),
          .to_mem(dmem_in[0]),
          .luterr(dmem_if_lutram_err));

  //------------------generate memory controller----------------
  dramctrl_fast  #(.no_retbuf_fullflag(1)) gen_memctrl(.*,
                  .imem_in,
                  .dmem_in,
                  .imem_out,
                  .dmem_out,
                  .mcif,
                  .luterr(dramctrl_lutram_err));      


  //------------------generate memory controller----------------
  debug_dma   gen_iu_dma(.*, .luterr(dma_luterr));

  //----------generate IRQ & timer-------------
  timer #(.addrmask(1)) gen_timer (.*, 
             // CPU interface
             .bus_in(io_out),
             .tick,
             .irq(irq_timer)                  //@M2
            );

   irqmp #(.NIRQ(1), .addrmask(2)) gen_irqmp(.*,
             // CPU interface
             .bus_in(io_out),
             .irqack,              //@xc
             .bus_out(irq_io_out),
             .irq(irq_timer)       //@M2
            );
    

  //----------generate timing model & performance counters-------------
//  tm_cpu_1ipc gen_tm(.*);
//  tm_cpu_none gen_tm(.*);
//  assign io_in = '{default:0};
//  tm_cpu_simple gen_tm(.*, .io_in(io_out), .io_out());
  //tm_cpu_l1 #(.NHOSTGLOBALCNT($bits(host_global_perf_counter))) gen_tm(.*, .io_in(io_out), .io_out(tm_io_out), .cpu2tm(cpu2tm_out), .tm2cpu(), .running(), .tick());
  
  always_ff @(posedge gclk.clk) begin
      ldst_out_4 <= iu2dcache.m2.ldst;//~memr.ts.dma_mode & memr.ts.run & (memr.ts.inst[31:30] == LDST) & ~memr.ts.replay & ~memr.ts.ucmode;    //count a LDST even if it traps
      ldst_out_3 <= ldst_out_4;
      ldst_out_2 <= ldst_out_3;
      ldst_out_1 <= ldst_out_2;
      ldst_out <= ldst_out_1;
      hostcycle_en[0] <= running;
      
      icmiss_en[0]   <= icache_iu2mem_cmd.valid;
      ldmiss_en[0]   <= (running & (dcache_iu2mem_cmd.cmd.D == DCACHE_LD)) ? dcache_iu2mem_cmd.valid : '0;
      stmiss_en[0]   <= (running & (dcache_iu2mem_cmd.cmd.D == DCACHE_WB)) ? dcache_iu2mem_cmd.valid : '0;
      nretired_en[0] <= comr.spr.pc_we;
      ldst_en[0]     <= ~memr.ts.dma_mode & memr.ts.run & (memr.ts.inst[31:30] == LDST) & ~memr.ts.replay & ~memr.ts.ucmode;    //count a LDST even if it traps
    blkcnt_en[0]   <= xcr.ts.run & dcacheblkcnt;
    rawcnt_en[0]   <= xcr.ts.run & dcacherawcnt;
    
    itlbmiss_en[0] <= xcr.ts.run & itlb_miss;
    dtlbmiss_en[0] <= xcr.ts.run & dtlb_miss;
    
    comr_r_dma  <= xcr.ts.dma_mode;
    comr_dma    <= comr_r_dma;
    comr_r_run  <= xcr.ts.run;
    comr_run    <= comr_r_run;
    
    replay_en[0]    <= comr.spr.replay & ~comr_dma & comr_run;
    microcode_en[0] <= comr.spr.ucmode & comr_run & ~comr_dma & ~comr.spr.replay;
    idlecnt_en[0]   <= running & ~xcr.ts.run;
    
    if (xcr.ts.inst[31:30]==FMT3 && xcr.ts.replay & xcr.ts.run) begin
      unique case(xcr.ts.inst[24:19])
    UMUL, SMUL, UMULCC, SMULCC, ISLL, ISRL, ISRA : replaymul_en[0] <= '1;
    default: replaymul_en[0] <= '0;
    endcase
    end
    else
      replaymul_en[0] <= '0;

    if (xcr.ts.inst[31:30]==FMT3 && xcr.ts.replay & xcr.ts.run) begin
      unique case(xcr.ts.inst[24:19])
        FPOP1: unique case(xcr.ts.inst[13:5])
            FADDD, FSUBD, FMULD,FADDS, FSUBS, FMULS, FSMULD, FITOS,FITOD,FSTOI,FDTOI : replayfpu_en[0] <= '1;
            default: replayfpu_en[0] <= '0;
            endcase
        FPOP2: unique case(xcr.ts.inst[13:5])
          FCMPD, FCMPED, FCMPS, FCMPES : replayfpu_en[0] <='1;
          default: replayfpu_en[0] <= '0;
          endcase
        default:replayfpu_en[0] <= '0;
      endcase
    end
    else 
      replayfpu_en[0] <= '0;
          
      hostcycle_en[1] <= hostcycle_en[0];      
      icmiss_en[1]    <= icmiss_en[0];
      ldmiss_en[1]    <= ldmiss_en[0];
      stmiss_en[1]    <= stmiss_en[0];
      nretired_en[1]  <= nretired_en[0];
      ldst_en[1]      <= ldst_en[0];    //count a LDST even if it traps      
      blkcnt_en[1]    <= blkcnt_en[0];
      rawcnt_en[1]    <= rawcnt_en[0];
      replay_en[1]    <= replay_en[0];
      replaymul_en[1] <= replaymul_en[0];
      replayfpu_en[1] <= replayfpu_en[0];
      microcode_en[1] <= microcode_en[0];
      idlecnt_en[1]   <= idlecnt_en[0];
      itlbmiss_en[1] <= itlbmiss_en[0];
      dtlbmiss_en[1] <= dtlbmiss_en[0];      
  end

  assign host_global_perf_counter = {idlecnt_en[1], microcode_en[1], replayfpu_en[1], replaymul_en[1], replay_en[1], rawcnt_en[1], blkcnt_en[1], dtlbmiss_en[1], itlbmiss_en[1], stmiss_en[1], ldmiss_en[1], icmiss_en[1]};
/*
  perfctr_host_counter  gen_perfctr(.gclk, .rst, 
                          .bus_out(io_in),
                          .bus_in(io_out),
                          
                          .hostcycle(hostcycle_en[1]),
                          .icmiss(icmiss_en[1]),
                          .ldmiss(ldmiss_en[1]),
                          .stmiss(stmiss_en[1]),
                          .nretired(nretired_en[1]),
                          .ldst(ldst_en[1]),
                          .blkcnt(blkcnt_en[1]),
                          .rawcnt(rawcnt_en[1]),
                          .replay(replay_en[1]),
                          .microcode(microcode_en[1]),
                          .idlecnt(idlecnt_en[1]),
                          .replayfpu(replayfpu_en[1]),
                          .replaymul(replaymul_en[1])
                  );

*/


    //------------------generate a flight recorder---------------------
  /*
  always_ff @(posedge gclk.clk) begin
   fr_din.inst       <= xcr.ts.inst;
   fr_din.pc         <= xcr.ts.pc;
   fr_din.tid        <= xcr.ts.tid;
   fr_din.ucmode     <= xcr.ts.ucmode;
   fr_din.replay     <= xcr.ts.replay;
   fr_din.mmu_replay <= dmmu2iu.replay;
   fr_din.dcache_replay <= dcache2iu.replay;
   fr_din.run        <= xcr.ts.run;
   fr_din.dma_mode   <= xcr.ts.dma_mode;
   fr_din.icmiss     <= xcr.ts.icmiss;
   fr_din.dtlbexception <= dmmu2iu.exception;
   fr_din.irq		 <= xcr.trap_res.irq_trap;
   
   fr_din.itlbexception   <= xc_immu_data.exception;
   fr_din.itlbmiss		  <= xc_immu_data.tlbmiss;   
   fr_din.immu_refill	  <= (dmmu2immu.op == tlb_refill);
   fr_din.error_mode      <= xc_error_mode;
   
   fr_dout_r <= fr_dout;
   
   m2_immu_data <= memr.immu_data;
   xc_immu_data <= m2_immu_data;
   
	if (rst | (xcr.ts.run & ~xcr.ts.replay & ~xcr.ts.ucmode & ~xcr.ts.dma_mode)) fdr_trigger_cnt <= '0;
	else if (xcr.ts.run & xcr.ts.replay & ~xcr.ts.ucmode & ~xcr.ts.dma_mode) fdr_trigger_cnt <= fdr_trigger_cnt + 1;
	
	fdr_trigger <= (fdr_trigger_cnt > 16) ? '1 : '0;
   end  
*/
//   flight_recorder #(.DWIDTH(FDRWIDTH)) fdr( .clk(gclk.clk), .rst, .din(fr_din), .dout(fr_dout)) /* synthesis syn_noprune=1 */;
  
  //------------------SEU Error detection logic-----------------
  always_ff @(posedge gclk.clk) begin
  	r_dmmu_dberr <= {dmmu_dberr, r_dmmu_dberr[$bits(r_dmmu_dberr)-1:1]};
  	r_immu_dberr <= {immu_dberr, r_immu_dberr[$bits(r_immu_dberr)-1:1]};
  	r_dmmu_sberr <= {dmmu_sberr, r_dmmu_sberr[$bits(r_dmmu_sberr)-1:1]};
  	r_immu_sberr <= {immu_sberr, r_immu_sberr[$bits(r_immu_sberr)-1:1]};
  end
  
  always_ff @(posedge gclk.clk2x) begin
    if (rst) begin 
      luterr_r <= '0;
      bramerr_r <= '0;
      sb_ecc_r <= '0;

      luterr_out <= '0;
      bramerr_out <= '0;
      sb_ecc_out <= '0;
    end
    else begin
      luterr_r <= {if_lutram_err, de_lutram_err, ex_lutram_err, xc_lutram_err, imem_if_lutram_err, dmem_if_lutram_err, dma_luterr, dramctrl_lutram_err, immu_lutram_err, dmmu_lutram_err};
      bramerr_r <= {de_bram_err, ex_bram_err, xc_bram_err,  r_dmmu_dberr[0], r_immu_dberr[0]};
      sb_ecc_r <= {de_sb_ecc, xc_sb_ecc, r_immu_sberr[0], r_dmmu_sberr[0]};

      luterr_out <= (luterr_out == 1'b0) ? |luterr_r : 1'b1;
      bramerr_out <= (bramerr_out == 1'b0) ? |bramerr_r : 1'b1;
      sb_ecc_out <= (sb_ecc_out == 1'b0) ? | sb_ecc_r : 1'b1;
      
    end   
  end
  
  always_ff @(posedge gclk.clk) begin
    if (rst)
      xc_error_out <= '0;
    else begin
      xc_error_r <= xc_error_mode;
      xc_error_out <= (xc_error_out == 1'b0) ? xc_error_r : 1'b1;
    end
  end
      

  assign luterr = luterr_out;
  assign bramerr = bramerr_out;
  assign sb_ecc = sb_ecc_out; 

  assign error1_led = xc_error_out;
        assign error2_led = luterr_out | bramerr_out | sb_ecc_out;
  
  
  //connect to disassembler
  
  //synthesis translate_off
  disassembler gen_disasm(.gclk, .rst, .xcr, .dcache_replay(dcache2iu.replay | dmmu2iu.replay));
  //synthesis translate_on  
  
endmodule

//synthesis translate_off
module sim_top;

parameter clkperiod = 5;

bit clk=0, clk200=0;
bit rst;
bit cpurst;

bit phy_rxclk, phy_gtxclk, phy_txen, phy_rxdv;
bit [7:0] phy_txd, phy_rxd;

//IO interface
//io_bus_out_type      io_in;
//io_bus_in_type       io_out;

wire [63:0]              ddr2_dq;
wire [13:0]              ddr2_a;
wire [2:0]               ddr2_ba;
wire                     ddr2_ras_n;
wire                     ddr2_cas_n;
wire                     ddr2_we_n;
wire [1:0]               ddr2_cs_n;
wire [1:0]               ddr2_odt;
wire [1:0]               ddr2_cke;
wire [7:0]               ddr2_dm;
wire [7:0]               ddr2_dqs;
wire [7:0]               ddr2_dqs_n;
wire [1:0]               ddr2_ck;
wire [1:0]               ddr2_ck_n;



default clocking main_clk @(posedge clk);
endclocking

initial begin
  forever #clkperiod clk = ~clk;
end

initial begin
  forever #4 phy_rxclk = ~phy_rxclk;
end

initial begin
  forever #2500ps clk200 = ~clk200;
end

initial begin

  rst    = '1;
  cpurst = '0;
//  io_in.retry = '0;
//  io_in.irl   = '0;
//  io_in.rdata = '0;

  ##10;
  rst = '1;
  
  ##200;
  rst = '1;
  
  ##10;
////  rst = '1;
  
  ##200;
////  cpurst = '1;
  
  ##10;
  cpurst = '0;
end

`ifndef MAGIC_MEM
mt16htf25664hy  gen_sodimm(
                         .dq(ddr2_dq),
                         .addr(ddr2_a),           //COL/ROW addr
                         .ba(ddr2_ba),            //bank addr
                         .ras_n(ddr2_ras_n),
                         .cas_n(ddr2_cas_n),
                         .we_n(ddr2_we_n),
                         .cs_n(ddr2_cs_n),
                         .odt(ddr2_odt),
                         .cke(ddr2_cke),
                         .dm(ddr2_dm),
                         .dqs(ddr2_dqs),
                         .dqs_n(ddr2_dqs_n),
                         .ck(ddr2_ck),
                         .ck_n(ddr2_ck_n)
                          );
`endif                          

mac_fedriver mac(
            .rxclk(phy_rxclk),
            .txclk(phy_gtxclk),
            .rst(cpurst),
            .rxdv(phy_rxdv),
            .rxd(phy_rxd),
            .txd(phy_txd),
            .txen(phy_txen));

fpga_top sim(.clkin_p(clk), 
            .clkin_n(~clk),
            .clk200_p(clk200),		//no use in simulation
            .clk200_n(~clk200),
            .rstin(rst),
            .cpurst,         
            .ddr2_dq,
            .ddr2_a,
            .ddr2_ba,
            .ddr2_ras_n,
            .ddr2_cas_n,
            .ddr2_we_n,
            .ddr2_cs_n,
            .ddr2_odt,
            .ddr2_cke,
            .ddr2_dm,
            .ddr2_dqs,
            .ddr2_dqs_n,
            .ddr2_ck,
            .ddr2_ck_n,
            .PHY_TXD(phy_txd),
            .PHY_TXEN(phy_txen),
            .PHY_TXER(),
            .PHY_GTXCLK(phy_gtxclk),
            .PHY_RXD(phy_rxd),
            .PHY_RXDV(phy_rxdv),
            .PHY_RXER(1'b0),
            .PHY_RXCLK(phy_rxclk),
//            .PHY_TXCLK(1'b0),
//            .PHY_COL(1'b0),
//            .PHY_CRS(1'b0),
            .PHY_RESET(),
            .TxD(),
            .error1_led(),
            .error2_led(),
            .RxD(1'b0)
            );



endmodule
//synthesis translate_on
