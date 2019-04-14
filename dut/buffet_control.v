`include "buffet_defines.v"

module buffet_control
        (
            clk,
            nreset_i,
            //Read in and out
            read_idx_i,
            read_idx_valid_i,
            read_data_ready_i,
            read_idx_o,
            read_idx_valid_o,
            read_idx_ready_o,
            read_will_update,
            read_is_shrink,
            // Push data
            push_data_i,
            push_data_valid_i,
            push_data_ready,
            push_data_o,
            push_idx_o,
            push_data_valid_o,
            // Updates
            update_data_i,
            update_idx_i,
            update_valid_i,
            update_data_o,
            update_idx_o,
            update_valid_o,
            update_ready_o,
            // Credits
            credit_ready,
            credit_out,
            credit_valid
        );


//------------------------------------------------------------------
//	                   PARAMETERS 
//------------------------------------------------------------------

parameter DATA_WIDTH = 32;
parameter ADDR_WIDTH = 8;
parameter SIZE = 2 ** ADDR_WIDTH;

localparam READY=2'b00, WAIT=2'b01, DISPATCH=2'b10;
//------------------------------------------------------------------
//	                   INPUT/OUTPUT PORTS
//------------------------------------------------------------------

input                       clk, nreset_i;

// Read Ports (In and Out)
input   [ADDR_WIDTH-1:0]    read_idx_i;
output  [ADDR_WIDTH-1:0]    read_idx_o;
input                       read_idx_valid_i;
input                       read_data_ready_i;
output                      read_idx_valid_o;
output                      read_idx_ready_o;
input                       read_will_update;
input                       read_is_shrink;

// Push Port
input   [DATA_WIDTH-1:0]    push_data_i;
output  [DATA_WIDTH-1:0]    push_data_o;
input                       push_data_valid_i;
output                      push_data_valid_o;
output  [ADDR_WIDTH-1:0]    push_idx_o;
output                      push_data_ready;

// Updates
input   [DATA_WIDTH-1:0]    update_data_i;
output  [DATA_WIDTH-1:0]    update_data_o;
input   [ADDR_WIDTH-1:0]    update_idx_i;
output  [ADDR_WIDTH-1:0]    update_idx_o;
input                       update_valid_i;
output                      update_valid_o;
output                      update_ready_o;

// Credits
input                       credit_ready;
output  [ADDR_WIDTH-1:0]    credit_out;
output                      credit_valid;

//------------------------------------------------------------------
//	                   REGISTERS
//------------------------------------------------------------------

reg     [ADDR_WIDTH-1:0]    head, tail;
reg     [1:0]               read_state;

// Output registers
reg     [ADDR_WIDTH-1:0]    read_idx_o_r, push_idx_o_r, update_idx_o_r, credit_out_r;
reg     [DATA_WIDTH-1:0]    push_data_o_r, update_data_o_r;
reg                         read_idx_valid_o_r, push_data_valid_o_r, update_valid_o_r, credit_valid_r;
reg                         read_idx_ready_o_r, update_ready_o_r;
reg     [ADDR_WIDTH-1:0]    read_idx_i_r, read_idx_stage_r;
reg                         read_idx_valid_i_r, read_idx_valid_stage_r;
reg                         stall_r;

reg     [ADDR_WIDTH-1:0]        scoreboard  [`SCOREBOARD_SIZE-1:0];
reg     [`SCOREBOARD_SIZE-1:0]  scoreboard_valid;

//------------------------------------------------------------------
//	                   WIRES 
//------------------------------------------------------------------

// Head Tail chase has two cases: (1) one where head is greater than tail and (2) vice versa
wire                        head_greater_than_tail = (head < tail)? 1'b0:1'b1;

// Distance between the tail and the end of the FIFO
wire    [ADDR_WIDTH-1:0]     tail_offset = SIZE - tail;

// Distance between head and tail (applicable in case 1)
wire    [ADDR_WIDTH-1:0]     head_tail_distance = head - tail;

// In case 1, head_tail_distance directly gives occupancy, in case (2) offset needs to be added to head.
wire    [ADDR_WIDTH-1:0]     occupancy = (head_greater_than_tail)? head_tail_distance :
                                        (head + tail_offset);

// Available space in the bbuffer
wire    [ADDR_WIDTH-1:0]     space_avail = SIZE - occupancy;

// Empty FIFO
wire                        empty = (occupancy == 1'b0)? 1'b1:1'b0;

// All the possible events
wire                        read_event = ~empty & read_idx_valid_i & ~read_is_shrink;
wire                        shrink_event = ~empty & read_idx_valid_i & read_is_shrink;
wire                        write_event = push_data_valid_i;
wire                        update_event = update_valid_i;
wire [1:0]                  event_cur = {read_event, shrink_event, write_event, update_event};

// check if the read is between the head and tail
    // This changes based on head_greater_than_tail value (first check if the read is valid)
wire                        read_valid_hgtt = ((read_idx_i_r < head) && (read_idx_i_r >= tail))? 1'b1 :1'b0;
wire                        read_valid_hgtt_n = ~read_valid_hgtt;
wire                        read_valid = (head_greater_than_tail)? read_valid_hgtt : read_valid_hgtt_n;
// WAR hazard is when you are trying to read something that is not present in the buffet yet - wait till you receive it.
// Caution: this might lead to a lock -- TODO a way to retire waiting reads.
wire                        war_hazard = ~read_valid;

// RAW hazard detection is simply checking the outstanding updates

wire    [`SCOREBOARD_SIZE-1:0]  match;

genvar i;
generate
for (i = 0; i < `SCOREBOARD_SIZE; i = i + 1) begin : SCOREBOARD_COMP
    assign match[i] = (scoreboard_valid[i])? ((scoreboard[i] == read_idx_i_r) ? 1'b1:1'b0) : 1'b0;
end
endgenerate

//Any match?
wire                        raw_hazard = |match;

// Pipeline should stall on gazards TODO
wire                        stall = raw_hazard | war_hazard | ~read_data_ready_i;

//------------------------------------------------------------------
//	                   SEQUENTIAL LOGIC
//------------------------------------------------------------------



//----------------------------------------------------------------------------------//

         //**********************//
        // *** Credit logic *** //
       //**********************//
       
// Reflects credit ready
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        credit_valid_r <= 1'b0;
    end
    else begin
        credit_valid_r <= credit_ready;
    end
end

// No Reset, reply with the available space in the buffer
always @(posedge clk) begin
    if(credit_ready) 
        credit_out_r <= space_avail;       
end

//----------------------------------------------------------------------------------//

         //**********************//
        // ***  Push Logic  *** //
       //**********************//
       
// Producer will never send more data than there is space --> due to credit req/rsp..
// Therefore, there is nothing tricky here - as you get the data, update the head 
// and push the data to the buffer.

//push  data output valid reflects the input 
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        push_data_valid_o_r <= 1'b0;
    end
    else begin
        push_data_valid_o_r <= push_data_valid_i;
    end
end

// Update the head (Counter wraps around)
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        head <= {ADDR_WIDTH{1'b0}};
    end
    else begin
        if(push_data_valid_i)
            head <= head + 1'b1;
    end
end

// Send the data off to the buffer
always @(posedge clk) begin
    if(push_data_valid_i)
        push_data_o_r <= push_data_i;
        push_idx_o_r  <= head;
end

//----------------------------------------------------------------------------------//

         //**********************//
        // ***  Update Logic ***//
       //**********************//
       
// If there is a separate write port for updates, this is straightforward too. 
// First, clear the entry in the scoreboard. Send the update with the address to the 
// buffer. We need not wait for the ack, as it need not wait.
// However, if writes and updates share a write path, then we need to wait for the 
// acknowledgement of update. TODO: Arbitration
// NOTE: This problem does not exist if the update gets static priority over the writes.

// Set the update valid
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        update_valid_o_r <= 1'b0;
    end
    else begin
        update_valid_o_r <= update_valid_i;
    end
end

// Send off update
always @(posedge clk) begin
    if(update_valid_i)
        update_data_o_r <= update_data_i;
end

// Always ready to take the updates in
assign  update_ready_o = 1'b1;

// We will update the scoreboard separately

//----------------------------------------------------------------------------------//

         //**********************//
        // ***  Read Logic   ***//
       //**********************//

// Read gets stalled if (1) tries to get something that is slated for an update (2) beyond the window.
// Otherwise, simply return the data.

// State Machine
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        read_state <= READY;
    end
    else begin
        case(read_state)

        // Check if there are hazards
        READY:
            read_state <= (read_idx_valid_i_r)? ((stall) ? WAIT : DISPATCH): READY;

        // Wait till hazards are cleared
        WAIT:
            read_state <= (stall)? WAIT:DISPATCH;

        // Dispatch and go back
        DISPATCH:
            read_state <= READY;

        endcase
    end
end

// this always block registers new read events 
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        read_idx_valid_i_r  <= 1'b0;
        read_idx_i_r        <= {ADDR_WIDTH{1'b0}};
    end
    else begin
        if(read_event & (read_state != WAIT)) begin
            read_idx_valid_i_r  <= read_idx_valid_i;
            read_idx_i_r        <= read_idx_i + tail;
        end
        else if((read_idx_valid_stage_r) & (read_state == DISPATCH)) begin
            read_idx_valid_i_r  <= 1'b1;
            read_idx_i_r        <= read_idx_stage_r;
        end
        else
            read_idx_valid_i_r  <= 1'b0;
    end
end

// When we are waiting for hazard to be cleared, there is a chance for one more
// read to appear (due to the propogation delay of ready signal). In that case.
// we need to stage that read to be considered after the hazard is cleared.
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        read_idx_valid_stage_r  <= 1'b0;
        read_idx_stage_r        <= {ADDR_WIDTH{1'b0}};
    end
    else begin
        if(read_event & (read_state == WAIT)) begin
            read_idx_valid_stage_r  <= read_idx_valid_i;
            read_idx_stage_r        <= read_idx_i + tail;
        end
    end
end

// Ready is pulled low whenever (1) You detect a hazard (2) waiting to resolve a hazard
// (3) there is a staged data already.
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        read_idx_ready_o_r <= 1'b0;
    end
    else
        read_idx_ready_o_r <= (
                                ((read_state == READY)&(read_idx_valid_i_r)&(stall))|
                                    (read_state == WAIT) |
                                        ((read_idx_valid_stage_r) & (read_state == DISPATCH))
                                            )? 1'b0 : 1'b1;
end

// --------------- Pipeline Output -- if clean, send output ------//

always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i)
        read_idx_valid_o_r <= 1'b0;
    else
        read_idx_valid_o_r <= (read_state == DISPATCH)?1'b1:1'b0;
end

always @(posedge clk) begin
    if(read_state == DISPATCH)
        read_idx_o_r <= read_idx_i_r;
end

//----------------------------------------------------------------------------------//

         //**********************//
        // ***  Shrink Logic ***//
       //**********************//

// If a valid shrink comes in, we update the tail. (This is the only driver for tail reg)
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) begin
        tail <= {ADDR_WIDTH{1'b0}};
    end
    else begin
        if(shrink_event)
            tail <= tail + read_idx_i;
    end
end

//----------------------------------------------------------------------------------//
//
         //**********************//
        // ***  Update Logic ***//
       //**********************//
       
always @(posedge clk or negedge nreset_i) begin
    if(~nreset_i) 
        scoreboard_valid <= {`SCOREBOARD_SIZE{1'b0}};
end

//------------------------------------------------------------------
//	                   ASSIGN OUTPUTS
//------------------------------------------------------------------

// Credits
assign credit_out = credit_out_r;
assign credit_valid = credit_valid_r;
// Push
assign push_idx_o = push_idx_o_r;
assign push_data_o = push_data_o_r;
assign push_data_valid_o = push_data_valid_o_r;
// Update
assign update_data_o = update_data_o_r;
assign update_idx_o = update_idx_o_r;
assign update_valid_o = update_valid_o_r;
assign update_ready_o = update_ready_o_r;
// Read
assign read_idx_o = read_idx_o_r;
assign read_idx_valid_o = read_idx_valid_o_r;
assign read_idx_ready_o = read_idx_ready_o_r;

endmodule
