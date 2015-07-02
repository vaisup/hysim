`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Kramer Straube/Brent Allen
//
// Create Date:    14:16:26 08/13/2014
// Design Name:
// Module Name:    WriteModule
// Project Name:   PCIE-Control
// Target Devices: XUPV5-LX110T
// Tool versions:
// Description:    Module for control of FPGA-simulated core write operation for
//                 HySim via PCI-Express
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////
`timescale    1ns/1ns

`ifndef SYNP94
import libconf::*;
import libiu::*;
import libio::*;
import libstd::*;
import libdebug::*;
import libtm::*;
import libopcodes::*;
import libtm_cache::*;
`else
`include "../cpu/libiu.sv"
`include "../io/libio.sv"
`include "../tm/libtm.sv"
`include "../tm/cpu/libtm_cache.sv"
`endif

module WriteMod(
   input          clk,
   input          rst_n,
   input  [127:0]  FPGA_data,
   input          enable,
   input          RAM_busy,
   output reg [10:0]   RAM_addr,
   output reg [31:0]  RAM_data,
   output reg        write_en,
   output reg         ready   );

   typedef enum bit [3:0] {idle,send0,send1,send2,send3,send0_wait,send1_wait,send2_wait,send3_wait,idle_wait} pcie_state_type;

   pcie_state_type state,v_state;

   reg    [(NTHREAD-1):0] prev_lead_bit;
   reg    [NTHREADIDMSB:0]   coreID, coreID_store;

   reg [127:0] FPGA_data_store;

   assign coreID = 6'b0;//FPGA_data[108:102];//figure this out
   assign coreID_store = 6'b0;//FPGA_data_store[108:102];

   always@(*) begin
     if (~rst_n) begin
      RAM_data = 32'h22222222;
      RAM_addr = 11'b0;
      ready = 1'b0;
      v_state = idle;
      write_en = 1'b0;
      end
   else begin
      case(state)
      idle: begin
        RAM_data = 32'hFFFFFFFF;
        RAM_addr = 11'b0;
        ready = 1'b1;
        write_en = 1'b0;
        if (enable) begin
          v_state = send0;
        end
        else begin
          v_state = idle;
        end
      end
      send0: begin
        RAM_data = 32'h11111111;//FPGA_data_store[31:0];
        RAM_addr = 11'h0;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = send0_wait;
      end
      send1: begin
        RAM_data = FPGA_data_store[63:32];
        RAM_addr = 11'h1;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = send1_wait;
      end
      send2: begin
        RAM_data = FPGA_data_store[95:64];
        RAM_addr = 11'h2;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = send2_wait;
      end
      send3: begin
        RAM_data = FPGA_data_store[127:96];
        RAM_addr = 11'h3;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = send3_wait;
      end
      send0_wait: begin
        RAM_data = 32'h11111111;//FPGA_data_store[31:0];
        RAM_addr = 11'h0;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = idle_wait;
      end
      send1_wait: begin
        RAM_data = FPGA_data_store[63:32];
        RAM_addr = 11'h1;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = idle_wait;
      end
      send2_wait: begin
        RAM_data = FPGA_data_store[95:64];
        RAM_addr = 11'h2;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = idle_wait;
      end
      send3_wait: begin
        RAM_data = FPGA_data_store[127:96];
        RAM_addr = 11'h3;
        write_en = 1'b1;
        ready = 1'b0;
        v_state = idle_wait;
      end
      idle_wait: begin
	write_en = 1'b0;
        if(~RAM_busy) begin
          v_state = idle;
        end
        else begin
          v_state = idle_wait;
        end
      end
      endcase
    end
   end

   always@(posedge clk) begin
      if (~rst_n) begin
        state <= idle;
        FPGA_data_store <= 128'b0;
        prev_lead_bit <= 'b0;
      end
      else begin
        state <= v_state;
      end
      if (enable && ready) begin
        FPGA_data_store[126:0] <= FPGA_data[126:0];
        FPGA_data_store[127] <= prev_lead_bit[coreID];
        prev_lead_bit[coreID] <= ~prev_lead_bit[coreID];
      end
   end
endmodule