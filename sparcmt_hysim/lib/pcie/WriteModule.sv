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
   output [10:0]   RAM_addr,
   output [31:0]  RAM_data,
   output         write_en,
   output          ready   );

   reg    [(NTHREAD-1):0] prev_lead_bit;
   reg    [NTHREADIDMSB:0]   coreID;
   reg   [3:0]                              write_ctr;

   always @(posedge clk) begin
      if (!rst_n) begin
           RAM_addr <= 1'b0;
           FPGA_data <= 1'b0;
           write_en <= 1'b0;
           FPGA_valid <= 1'b0;
           prev_lead_bit <= 'b0;
           write_en <= 'b0;
           ready <= 1’b0;
      end

      if (enable) begin
           coreID <= FPGA_data[108:102];//figure this out
           RAM_addr <= coreID << 4;
           RAM_data <= {(~prev_lead_bit[coreID]),FPGA_data[126:96]};
           prev_lead_bit[coreID] <= ~prev_lead_bit[coreID];
           write_ctr <= 2'b3;//worried about timing of the RAM writes…
           write_en <= 1’b1;
           ready <= 1’b0;
        end
      else begin
             if (write_ctr != 0) begin
               write_ctr <= write_ctr -1;
               RAM_data <= FPGA_data[32*write_ctr -1: 32 * (write_ctr -1)];
               RAM_addr <= coreID <<4 + (4 - write_ctr);
               write_en <= 1’b1;
               ready <= 1’b0;
             end
             else begin
             	RAM_data <= 32'd0;
             	write_en <= 1'b0;
                ready <= 1’b1;
              end
      end
           
   end
endmodule