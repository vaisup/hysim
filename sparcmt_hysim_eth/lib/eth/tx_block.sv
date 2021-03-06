`timescale 1ns / 1ps

module eth_tx_block #(
  parameter mac_addr = 48'h112233445566)
(
	input	bit		clk,
	input	bit		reset,
	input	bit		tx_ack,
	input	bit		ack_empty,
	input	bit		ack_data,
	input	bit		send_data_empty,
	input bit [15:0] tx_len,
	input	bit [31:0]	din,
	
	output bit ack_re,
	output bit send_data_re,
	output	bit [7:0]	tx_data,
	output	bit		tx_en,
	output	bit [9:0]	addr,
	
	input bit [3:0] mac_lsn,
	input bit mem_ack,
	input bit [127:0] din_mem
);

  typedef enum bit [2:0] {tx_idle, tx_header_start, tx_header_data, tx_send_nack, tx_send_data, tx_send_mem_data} tx_block_state_type;//added new states

  tx_block_state_type state, nstate;
  bit [3:0]	rom_addr;
  bit [7:0] 	rom_dout;
  bit 		romcount_reset; 

  bit [10:0]	addr_count;
  bit		addrcount_reset;
  bit 		addrcount_ce;

  bit [1:0]	packet_type;
  bit [2:0]	tx_data_sel;
  bit [1:0]	bram_sel;
  bit [3:0]     mem_bram_sel;
  bit [7:0]	bram_data, mem_bram_data;

  tx_header_rom gen_tx_rom(.addr(rom_addr), .dout(rom_dout), .mac_lsn);

// 4:1 mux to select where outgoing data comes from
  always_comb begin
     unique case (tx_data_sel)
	0: tx_data = rom_dout;
	1: tx_data = bram_data;
	2: tx_data = 8'hAA;
	3: tx_data = 8'hBB;
	4: tx_data = bram_mem_data;
     endcase
  end

  assign addr = addr_count;
  assign bram_sel = rom_addr[1:0];
  assign mem_bram_sel = rom_addr;//assign for larger selection options

// 4:1 mux to select which byte of data word from BRAM to send
  always_comb begin
     unique case (bram_sel)
	0: bram_data = din[31:24];
	1: bram_data = din[23:16];
	2: bram_data = din[15:8];
	3: bram_data = din[7:0]; //add alternate bram_data for larger input size of mem data
     endcase
  end

// 4:1 mux to select which byte of data word from mem BRAM to send
  always_comb begin
     unique case (mem_bram_sel)
	0: mem_bram_data = din_mem[127:120];
	1: mem_bram_data = din_mem[119:112];
	2: mem_bram_data = din_mem[111:104];
	3: mem_bram_data = din_mem[103:96]; //add alternate bram_data for larger input size of mem data
	4: mem_bram_data = din_mem[95:88];
	5: mem_bram_data = din_mem[87:80];
	6: mem_bram_data = din_mem[79:72];
	7: mem_bram_data = din_mem[71:64]; //add alternate bram_data for larger input size of mem data
	8: mem_bram_data = din_mem[63:56];
	9: mem_bram_data = din_mem[55:48];
	10: mem_bram_data = din_mem[47:40];
	11: mem_bram_data = din_mem[39:32]; //add alternate bram_data for larger input size of mem data
	12: mem_bram_data = din_mem[31:24];
	13: mem_bram_data = din_mem[23:16];
	14: mem_bram_data = din_mem[15:8];
	15: mem_bram_data = din_mem[7:0]; //add alternate bram_data for larger input size of mem data
     endcase
  end

  always_comb begin
     tx_en = '0;
     ack_re = '0;
     send_data_re = '0;
     
     tx_data_sel = '0;
     romcount_reset = '1;
     addrcount_reset = '1;
     addrcount_ce = '0;
     nstate = state;

     unique case (state)
     
     tx_idle: begin
	     if (~ack_empty || ~send_data_empty) 
	       nstate = tx_header_start;
     end
     
     tx_header_start: begin
	       tx_en = '1;
	       if (tx_ack) begin
	         romcount_reset = '0;
	       nstate = tx_header_data;
    	    end
     end
     
     tx_header_data: begin
        tx_en = '1;
	      romcount_reset = '0;
	      if (rom_addr == 13 && ~ack_empty && ~ack_data) 
	      begin
	         ack_re = '1;	        
	     	   nstate = tx_send_nack;
	     	end
	      if (rom_addr == 15 && ~ack_empty && ack_data) //add new mem_ack section for sending payload in addition to channging the header -  && ~mem_ack
	      begin
	         ack_re = '1; //read next ack
	         nstate = tx_idle; //go to idle
	      end
	      /**if (rom_addr == 12 && ~ack_empty && ack_data && mem_ack) //add new mem_ack section for sending payload in addition to channging the header
	      begin
	         ack_re = '1; //need to change to send data for mem response after sending header
	         nstate = tx_idle; //check about tx_len needing to be updated - input so need to change based on input - used to be tx_send_mem_data
	      end**/
	      if (rom_addr == 15 && ~send_data_empty) 
	      begin
	         send_data_re = '1;
	         if (tx_len == 0)
		          nstate = tx_idle;
		       else
		          nstate = tx_send_data;
		    end
     end
        
     tx_send_nack: begin //can reuse same nack for mem_response too
	      tx_en = '1;
	      tx_data_sel = 3'b011;//nack data select
	      romcount_reset = '0;
	      if (rom_addr == 15)
		       nstate = tx_idle;
     end
     
     tx_send_data: begin
	       addrcount_reset = '0;
	       tx_en = '1;
	       romcount_reset = '0;
	       tx_data_sel = 3'b001;//bram data select
	       if (bram_sel == 1)
		        addrcount_ce = '1;
	       if (bram_sel == 3 && addr_count == tx_len)
		        nstate = tx_idle;
     end

     tx_send_mem_data: begin //send mem data with mem ack header
	       addrcount_reset = '0;
	       tx_en = '1; //send data
	       romcount_reset = '0;//allow rom counter to increase to send the data
	       tx_data_sel = 3'b100; //bram_mem data
	       if (bram_sel == 1)
		        addrcount_ce = '1;//start counting the addr
	       if (bram_sel == 15 && addr_count == tx_len)//make sure length matches and bram iterates through
		        nstate = tx_idle;//go to idle next
     end
     
     endcase
  end

  always_ff @(posedge clk) begin
    if (reset)
        state <= tx_idle;
    else 
	     state <= nstate;

    if (romcount_reset)
        rom_addr <= '0;
    else 
        rom_addr <= rom_addr + 1;

    if (addrcount_reset)
	     addr_count <= '0;
    else if (addrcount_ce)
	     addr_count <= addr_count+1;

  end
endmodule

module tx_header_rom #(
  parameter mac_addr = 48'h112233445566)
(input bit [3:0] addr, output bit [7:0] dout, input bit [3:0] mac_lsn);	
	always_comb begin
		unique case(addr)
		0: dout = 8'hFF;
		1: dout = 8'hFF;
		2: dout = 8'hFF;
		3: dout = 8'hFF;
		4: dout = 8'hFF;
		5: dout = 8'hFF;
		6: dout = mac_addr[47:40];
		7: dout = mac_addr[39:32];
		8: dout = mac_addr[31:24];
		9: dout = mac_addr[23:16];
		10: dout = mac_addr[15:8];
		11: dout = {mac_addr[7:4], mac_lsn};
		12: dout = 8'h88;
		13: dout = 8'hFC; //mem response ack header - count increases before dout is read
		14: dout = 8'hAA;
		15: dout = 8'hAA;
		endcase
	end
endmodule
