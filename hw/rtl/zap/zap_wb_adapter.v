//
// Implements store FIFO.
// Released under GPL v2.
//

`default_nettype none

module zap_wb_adapter (

// Clock.
input wire                   i_clk,
input wire                   i_reset,

// Processor Wishbone interface. These come from the Wishbone registered
// interface.
input wire                   I_WB_CYC,
input wire                   I_WB_STB,   
input wire [3:0]             I_WB_SEL,     
input wire [2:0]             I_WB_CTI,   
input wire [31:0]            I_WB_ADR,    
input wire [31:0]            I_WB_DAT,    
input wire                   I_WB_WE,
output reg [31:0]       O_WB_DAT,    
output reg              O_WB_ACK,     

// Wishbone interface.
output reg                   o_wb_cyc,
output reg                   o_wb_stb,
output wire     [31:0]       o_wb_dat,
output wire     [31:0]       o_wb_adr,
output wire     [3:0]        o_wb_sel,
output wire     [2:0]        o_wb_cti,
output wire                  o_wb_we,
input wire      [31:0]       i_wb_dat,
input wire                   i_wb_ack

);

`include "zap_defines.vh"
`include "zap_localparams.vh"

reg  fsm_write_en;
reg  [69:0] fsm_write_data;
wire w_eob;
wire w_full;

assign    o_wb_cti = {w_eob, 1'd1, w_eob};

wire w_emp;

// {SEL, DATA, ADDR, EOB, WEN} = 4 + 64 + 1 + 1 = 70 bit.
zap_sync_fifo #(.WIDTH(70), .DEPTH(32), .FWFT(1'd0)) U_STORE_FIFO (
.i_clk          (i_clk),
.i_reset        (i_reset),
.i_ack          ((i_wb_ack && o_wb_stb) || emp_ff),
.i_wr_en        (fsm_write_en),
.i_data         (fsm_write_data),
.o_data         ({o_wb_sel, o_wb_dat, o_wb_adr, w_eob, o_wb_we}),
.o_empty        (w_emp),
.o_full         (w_full),
.o_empty_n      (),
.o_full_n       (),
.o_full_n_nxt   ()
);

reg emp_ff;
reg [31:0] ctr_nxt, ctr_ff;
reg [31:0] dff, dnxt;
reg ack;        // ACK write channel.
reg ack_ff;     // Read channel.

localparam IDLE = 0;
localparam PRPR_RD_SINGLE = 1;
localparam PRPR_RD_BURST = 2;
localparam WRITE = 3;
localparam WAIT1 = 5;
localparam WAIT2 = 6;
localparam NUMBER_OF_STATES = 7;

reg [$clog2(NUMBER_OF_STATES)-1:0] state_ff, state_nxt;

// FIFO pipeline register.
always @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                emp_ff   <= 1'd1;
                o_wb_stb <= 1'd0;
                o_wb_cyc <= 1'd0;
        end
        else if ( emp_ff || (i_wb_ack && o_wb_stb) )
        begin
                emp_ff   <= w_emp;
                o_wb_stb <= !w_emp;
                o_wb_cyc <= !w_emp;
        end
end

// Flip flop clocking block.
always @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                state_ff <= IDLE;
                ctr_ff   <= 0;
                dff      <= 0;
        end
        else
        begin
                state_ff <= state_nxt;
                ctr_ff   <= ctr_nxt;
                dff      <= dnxt;
        end
end

// Reads from the Wishbone bus are flopped.
always @ (posedge i_clk)
begin
        if ( i_reset )
        begin
                ack_ff  <= 1'd0;
        end
        else if ( !o_wb_we && o_wb_cyc && o_wb_stb && i_wb_ack )
        begin
                ack_ff   <= 1'd1;
                O_WB_DAT <= i_wb_dat;
        end
        else
        begin
                ack_ff <= 1'd0;
        end
end

localparam BURST_LEN = 4;

// OR from flop and mealy FSM output.
always @* O_WB_ACK = ack_ff | ack;

// State machine.
always @*
begin
        state_nxt = state_ff;
        ctr_nxt = ctr_ff;
        ack = 0;
        dnxt = dff;
        fsm_write_en = 0;
        fsm_write_data = 0;

        case(state_ff)
        IDLE:
        begin
                ctr_nxt = 0;
                dnxt = 0;

                if ( I_WB_STB && I_WB_WE && !o_wb_stb ) // Wishbone write request 
                begin
                        // Simply buffer stores into the FIFO.
                        state_nxt = WRITE;
                end   
                else if ( I_WB_STB && !I_WB_WE && !o_wb_stb ) // Wishbone read request
                begin
                        // Write a set of reads into the FIFO.
                        if ( I_WB_CTI == CTI_BURST ) // Burst of 4 words. Each word is 4 byte.
                        begin
                                state_nxt = PRPR_RD_BURST;
                                //state_nxt = PRPR_RD_SINGLE; //PRPR_RD_BURST;
                                $display("Read burst requested! Address base = %x", I_WB_ADR);
                                //$stop;
                        end
                        else // Single.
                        begin
                                state_nxt = PRPR_RD_SINGLE; 
                        end
                end
        end

        PRPR_RD_SINGLE: // Write a single read token into the FIFO.
        begin
                if ( !w_full )
                begin
                        state_nxt = WAIT1;
                        fsm_write_en = 1'd1;
                        fsm_write_data = {      I_WB_SEL, 
                                                I_WB_DAT, 
                                                I_WB_ADR, 
                                                I_WB_CTI != CTI_BURST ? 1'd1 : 1'd0, 
                                                1'd0};
                end
        end

        PRPR_RD_BURST: // Write burst read requests into the FIFO.
        begin
                if ( O_WB_ACK )
                begin
                        dnxt = dff + 1'd1;
                        $display($time, "EARLY ACK READ BURST. DATA IS %x", O_WB_DAT);
                        //$stop;
                end

                if ( ctr_ff == BURST_LEN * 4 )
                begin
                        ctr_nxt = 0;
                        state_nxt = WAIT2; // FIFO prep done.
                end
                else if ( !w_full )
                begin: blk1
                        reg [31:0] adr;
                        adr = {I_WB_ADR[31:4], 4'd0} + ctr_ff; // Ignore lower 4-bits.

                        fsm_write_en = 1'd1;
                        fsm_write_data = {      I_WB_SEL, 
                                                I_WB_DAT, 
                                                adr, 
                                                ctr_ff == 12 ? 1'd1 : 1'd0, 
                                                1'd0 };
                        ctr_nxt = ctr_ff + 4;

                        $display($time, "READ_BURST :: Writing data SEL = %x DATA = %x ADDR = %x EOB = %x WEN = %x to the FIFO", fsm_write_data[69:66], fsm_write_data[65:34], fsm_write_data[33:2], fsm_write_data[1], fsm_write_data[0]);
                        //$stop;
                end                
        end

        WRITE:
        begin
                // As long as requests exist, write them out to the FIFO.
                if ( I_WB_STB && I_WB_WE )
                begin
                        if ( !w_full )
                        begin
                                fsm_write_en    = 1'd1;
                                fsm_write_data  =  {I_WB_SEL, I_WB_DAT, I_WB_ADR, I_WB_CTI != CTI_BURST ? 1'd1 : 1'd0, 1'd1};
                                ack = 1'd1;
                        end
                end
                else // Writes done!
                begin
                        state_nxt = IDLE;
                end
        end

        WAIT1: // Wait for single read to complete.
        begin
                if ( O_WB_ACK )
                begin
                        state_nxt = IDLE;
                end
        end

        WAIT2: // Wait for burst reads to complete.
        begin
                if ( O_WB_ACK )
                begin
                        dnxt = dff + 1;
                        $display("READ BURST! ACK sent. Data provided is %x", O_WB_DAT);
                        //$stop;
                end

                if ( dff == BURST_LEN && !o_wb_stb )
                begin
                        state_nxt = IDLE;
                end
        end

        endcase
end

endmodule
