// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

`include "soc.vh"

module tlb_top #(
  parameter ENTRIES      = 8,
  parameter NR_MINIONS   = 1,
  parameter NR_MINIONS_L = (NR_MINIONS == 1) ? 1 : $clog2(NR_MINIONS)
) (
  // System signals
  input  logic                             clock,
  input  logic                             reset,
  // ESRs
  input  tlb_entry_type                    vmspagesize,
  input  logic                             coop_mode,
  // Request to the TLB
  input  logic [NR_MINIONS_L-1:0]          req_min_id,
  input  tlb_req                           req_data,
  input  logic                             req_valid,
  // Response with the physical bits
  output tlb_resp                          resp_data,
  // TLB/PTW control
  input  minion_satp_info [NR_MINIONS-1:0] satp_info,
  input  minion_satp_info [NR_MINIONS-1:0] matp_info,
  input  logic [NR_MINIONS-1:0]            tlb_invalidate,
  // PTW request
  output minion_ptw_req                    ptw_req_data,
  output logic                             ptw_req_valid,
  input  logic                             ptw_req_ready,
  output logic                             ptw_invalidate,
  // PTW response
  input  minion_ptw_pte                    ptw_resp_data,
  input  logic                             ptw_resp_valid,
  // VM enabled
  output logic                             vm_enabled
);

// PARAMETERS
localparam TLB_CACHE_IDX_SZ         = $clog2(ENTRIES);
localparam ENTRIES_PER_MIN          = ENTRIES / NR_MINIONS;
localparam TLB_CACHE_IDX_SZ_PER_MIN = $clog2(ENTRIES_PER_MIN);
localparam TAG_SZ                   = `VA_TRANS_SIZE - TLB_CACHE_IDX_SZ_PER_MIN;

// INTERNAL FUNCTIONS
function automatic logic [TAG_SZ-1:0] tlb_tag(logic [`VA_TRANS_RANGE] vpn, tlb_entry_type typ,
                                              logic coop_mode);
  if (coop_mode) begin
    // In cooperative mode, the whole cache is shared amond all the minions
    case (typ)
      tlb_entry_type_2M: tlb_tag = TAG_SZ'({vpn[`VA_TRANS_MSB : (`VA_UNTRANS_SIZE + `PTW_PG_IDX_SZ + TLB_CACHE_IDX_SZ)],
                                            (`PTW_PG_IDX_SZ)'(1'b0)});
      tlb_entry_type_1G: tlb_tag = TAG_SZ'({vpn[`VA_TRANS_MSB : (`VA_UNTRANS_SIZE + 2 * `PTW_PG_IDX_SZ + TLB_CACHE_IDX_SZ)],
                                            (2 * `PTW_PG_IDX_SZ)'(1'b0)});
      default:           tlb_tag = TAG_SZ'(vpn[`VA_TRANS_MSB : (`VA_UNTRANS_SIZE + TLB_CACHE_IDX_SZ)]);
    endcase
  end else begin
    // Otherwise, cache entries are split among all the minions
    case (typ)
      tlb_entry_type_2M: tlb_tag = {vpn[`VA_TRANS_MSB : (`VA_UNTRANS_SIZE + `PTW_PG_IDX_SZ + TLB_CACHE_IDX_SZ_PER_MIN)],
                                    (`PTW_PG_IDX_SZ)'(1'b0)};
      tlb_entry_type_1G: tlb_tag = {vpn[`VA_TRANS_MSB : (`VA_UNTRANS_SIZE + 2 * `PTW_PG_IDX_SZ + TLB_CACHE_IDX_SZ_PER_MIN)],
                                    (2 * `PTW_PG_IDX_SZ)'(1'b0)};
      default:           tlb_tag = vpn[`VA_TRANS_MSB : (`VA_UNTRANS_SIZE + TLB_CACHE_IDX_SZ_PER_MIN)];
    endcase
  end
endfunction

function automatic logic [TLB_CACHE_IDX_SZ-1:0] tlb_index(logic [NR_MINIONS_L-1:0] min_id,
                                                          logic [`VA_TRANS_RANGE] vpn,
                                                          tlb_entry_type typ, logic coop_mode);
  if (coop_mode) begin
    // In cooperative mode, the whole cache is shared amond all the minions
    case (typ)
      tlb_entry_type_2M: tlb_index = vpn[(`VA_UNTRANS_SIZE + `PTW_PG_IDX_SZ) +: TLB_CACHE_IDX_SZ];
      tlb_entry_type_1G: tlb_index = vpn[(`VA_UNTRANS_SIZE + 2 * `PTW_PG_IDX_SZ) +: TLB_CACHE_IDX_SZ];
      default:           tlb_index = vpn[`VA_UNTRANS_SIZE +: TLB_CACHE_IDX_SZ];
    endcase
  end else begin
    // Otherwise, cache entries are split among all the minions
    case (typ)
      tlb_entry_type_2M: tlb_index = TLB_CACHE_IDX_SZ'({min_id, vpn[(`VA_UNTRANS_SIZE + `PTW_PG_IDX_SZ) +: TLB_CACHE_IDX_SZ_PER_MIN]});
      tlb_entry_type_1G: tlb_index = TLB_CACHE_IDX_SZ'({min_id, vpn[(`VA_UNTRANS_SIZE + 2 * `PTW_PG_IDX_SZ) +: TLB_CACHE_IDX_SZ_PER_MIN]});
      default:           tlb_index = TLB_CACHE_IDX_SZ'({min_id, vpn[`VA_UNTRANS_SIZE +: TLB_CACHE_IDX_SZ_PER_MIN]});
    endcase
  end
endfunction

// INTERNAL DECLARATIONS
logic                         coop_mode_reg;
logic                         tlb_invalidate_reg;
logic [NR_MINIONS-1:0]        tlb_invalidated, tlb_invalidated_next;
logic                         ptw_req_invalidated;
logic [`CSR_PRV_SZ-1:0]       privilege_mode;
logic [TAG_SZ-1:0]            req_tag;
logic                         priv_mode_uses_vm;
logic [`CSR_SATP_MODE_SZ-1:0] vm_mode;
logic [`PA_TRANS_SIZE-1:0]    vm_ppn;
logic                         invalid_address;
tlb_state                     state;
logic [NR_MINIONS_L-1:0]      req_min_id_reg;
logic [NR_MINIONS-1:0]        req_min_mask;
logic [`VA_TRANS_RANGE]       req_vpn_reg;
logic [TAG_SZ-1:0]            req_tag_reg;
// Cache
logic                         rf_latch_wr_en;
logic                         rf_latch_wr_en_early;
logic                         rf_latch_wr_en_early_p2; // Phase 2 version of the early write enable
logic [TLB_CACHE_IDX_SZ-1:0]  tlb_cache_waddr;
logic                         tlb_cache_sr_rf_wdata;
logic                         tlb_cache_sw_rf_wdata;
logic                         tlb_cache_sx_rf_wdata;
tlb_entry_data_t              tlb_cache_wdata;
logic [TLB_CACHE_IDX_SZ-1:0]  tlb_cache_raddr;
logic [TAG_SZ-1:0]            tlb_cache_rtag;
tlb_entry_data_t              tlb_cache_rdata;
logic [ENTRIES-1:0]           tlb_cache_valid;
logic                         tlb_cache_hit;
logic                         tlb_miss;
logic                         priv_ok, w_perm_ok, r_perm_ok, x_perm_ok;
logic                         tlb_xcpt_accessed;
logic                         tlb_xcpt_dirty;
// PTW request
minion_ptw_req                ptw_req_data_next;
// PTW response
logic                         pte_is_leaf;
minion_ptw_pte                ptw_resp_data_reg;
logic                         ptw_resp_valid_reg;

logic ff_en;
assign ff_en = (coop_mode_reg ^ coop_mode) | (tlb_invalidate_reg ^ (|tlb_invalidate)) | (|(tlb_invalidated ^ tlb_invalidated_next));

//          CLK    RST    EN                                       DOUT                DIN                   DEF
`RST_EN_FF (clock, reset, ff_en,                                   coop_mode_reg,      coop_mode,            1'b0)
`RST_EN_FF (clock, reset, ff_en,                                   tlb_invalidate_reg, |tlb_invalidate,      1'b0)
`RST_EN_FF (clock, reset, ff_en,                                   tlb_invalidated,    tlb_invalidated_next, 1'b0)
`EN_FF     (clock,        ptw_resp_valid,                          ptw_resp_data_reg,  ptw_resp_data)
`RST_FF    (clock, reset,                                          ptw_resp_valid_reg, ptw_resp_valid,       1'b0)

// Request to the TLB
// ------------------
// If privilege mode is modified (mprv) take machine previous privilege mode (mpp),
// Otherwise, use current privilege mode (prv)
// For instruction fetching, always use current privilege mode (prv)
assign privilege_mode = req_data.status.mprv && !req_data.instruction ? req_data.status.mpp : req_data.status.prv;

assign req_tag = tlb_tag(req_data.vpn, vmspagesize, coop_mode_reg);
// Virtual memory is not used when fetching instructions in debug mode or when mprv is 0 in debug mode
assign priv_mode_uses_vm = (req_data.status.mprv && !req_data.instruction) || !req_data.status.debug;
assign vm_mode = (privilege_mode == `CSR_PRV_M) ? matp_info[req_min_id].mode : satp_info[req_min_id].mode;
assign vm_ppn = (privilege_mode == `CSR_PRV_M) ? matp_info[req_min_id].ppn : satp_info[req_min_id].ppn;
assign vm_enabled = (vm_mode != `CSR_SATP_MODE_BARE) && priv_mode_uses_vm && !req_data.passthrough;

// Define an invalid address to assert an access fault
always_comb begin
  if (vm_mode == `CSR_SATP_MODE_SV48) begin
    invalid_address = req_data.msb_err;
  end else if (vm_mode == `CSR_SATP_MODE_SV39) begin
    invalid_address = req_data.msb_err ||
                      !(|req_data.vpn[`VA_TRANS_MSB:`VA39_MSB] == 1'b0 || &req_data.vpn[`VA_TRANS_MSB:`VA39_MSB] == 1'b1); // bits[47:39] are not same to bit 38, so address is invalid
  end else begin
    invalid_address = 1'b0;
  end
end

// Manage an invalidate request
// On invalidation, invalidate the cache and wait for any outstanding request to discard it
always_comb begin
  tlb_invalidated_next = tlb_invalidated;

  // If there is an outstanding request, wait for response
  if ((state == `TLB_S_READY) || ((state == `TLB_S_WAIT) && ptw_resp_valid_reg)) begin
    tlb_invalidated_next = '0;
  end

  tlb_invalidated_next |= tlb_invalidate;
end
// In cooperative mode, PTW requests are invalidated when any minion notifies
// an invalidation
// Otherwise, PTW requests are only invalidated if invalidate pulse for the
// corresponding minion id is asserted
assign req_min_mask = 1'b1 << req_min_id_reg;
assign ptw_req_invalidated = (coop_mode_reg & |tlb_invalidated) | (~coop_mode_reg & |(req_min_mask & tlb_invalidated));

// FSM
// ---
logic clock_fsm;
logic en_clock_fsm;
assign en_clock_fsm = state != `TLB_S_READY || req_valid && tlb_miss || reset;
et_clk_gate clk_gate_fsm (
  .enclk(clock_fsm),
  .en   (en_clock_fsm),
  .clk  (clock),
  .te   (1'b0)
);

always_ff @(posedge clock_fsm) begin
  if (reset) begin
    state <= `TLB_S_READY;
    ptw_req_valid <= 1'b0;
  end else begin
    case (state)
      `TLB_S_READY: begin
        // Save request information if there is a miss to send it to PTW
        // and cache it
        if (req_valid && tlb_miss && !invalid_address) begin
          state <= `TLB_S_REQUEST;
          req_min_id_reg <= req_min_id;
          req_vpn_reg <= req_data.vpn;
          req_tag_reg <= req_tag;
          ptw_req_data <= ptw_req_data_next;
          ptw_req_valid <= 1'b1;
        end
      end

      `TLB_S_REQUEST: begin
        if (ptw_req_invalidated) begin
          state <= `TLB_S_READY;
          ptw_req_valid <= 1'b0;
        end else if (ptw_req_ready) begin
          // Wait for PTW to be ready to accept a request
          state <= `TLB_S_WAIT;
          ptw_req_valid <= 1'b0;
        end
      end

      `TLB_S_WAIT: begin
        // Wait for PTW response
        if (ptw_resp_valid_reg) begin
          state <= `TLB_S_READY;
        end
      end
    endcase
  end
end

// PTW request
// -----------
assign ptw_req_data_next.satp_mode = vm_mode;
assign ptw_req_data_next.satp_ppn  = vm_ppn;
assign ptw_req_data_next.prv       = req_data.status.prv;
assign ptw_req_data_next.addr      = req_data.vpn;

assign ptw_invalidate = tlb_invalidate_reg;

// PTW response
// ------------
// A valid leaf PTE has been found
assign pte_is_leaf = ptw_resp_data_reg.v && (ptw_resp_data_reg.r || (ptw_resp_data_reg.x && !ptw_resp_data_reg.w)) && !ptw_resp_data_reg.access_fault;

// TLB cache
// ---------
assign rf_latch_wr_en       = ~ptw_req_invalidated & ptw_resp_valid_reg & ~ptw_resp_data_reg.canceled_req;
assign rf_latch_wr_en_early = ~(|tlb_invalidated_next) & ptw_resp_valid & ~ptw_resp_data.canceled_req;

`LATCH_P2(clock, rf_latch_wr_en_early_p2, rf_latch_wr_en_early)

// Set cache write address
assign tlb_cache_waddr = tlb_index(req_min_id_reg, req_vpn_reg, vmspagesize, coop_mode_reg);

// Pre-calculate actual permisions
assign tlb_cache_sr_rf_wdata = pte_is_leaf & ptw_resp_data_reg.r;
assign tlb_cache_sw_rf_wdata = pte_is_leaf & ptw_resp_data_reg.w;
assign tlb_cache_sx_rf_wdata = pte_is_leaf & ptw_resp_data_reg.x;

// Set cache write address data
assign tlb_cache_wdata = '{ptw_access_fault: ptw_resp_data_reg.access_fault,   // PTW access fault
                           expected_ex_mode: ptw_resp_data_reg.rsvd_for_hw[0], // Expected execution mode
                           dirty:            ptw_resp_data_reg.d,              // PTE dirty bit
                           access:           ptw_resp_data_reg.a,              // PTE access bit
                           sx:               tlb_cache_sx_rf_wdata,            // execute permission
                           sw:               tlb_cache_sw_rf_wdata,            // write permission
                           sr:               tlb_cache_sr_rf_wdata,            // read permission
                           u:                ptw_resp_data_reg.u,              // user privilege
                           ppn:              ptw_resp_data_reg.ppn[`PA_TRANS_SIZE-1:0]};

rf_latch_1r_1w #(
  .WIDTH           (TAG_SZ + $bits(tlb_entry_data_t)),
  .ENTRIES         (ENTRIES),
  .LEVEL2_CLK_GATE (1)
) tlb_cache_rf (
  .clk             (clock),
  .wr_en_a         (rf_latch_wr_en),
  .wr_data_a_en_1p (rf_latch_wr_en_early_p2),
  .wr_addr_a       (tlb_cache_waddr),
  .wr_data_a       ({req_tag_reg, tlb_cache_wdata}),
  .rd_addr_a       (tlb_cache_raddr),
  .rd_data_a       ({tlb_cache_rtag, tlb_cache_rdata}),
  .test_en         (1'b0)
);

always_ff @(posedge clock) begin
  if (reset) begin
    tlb_cache_valid <= '0;
  end else begin
    if (ptw_resp_valid_reg && !ptw_resp_data_reg.canceled_req) begin
      tlb_cache_valid[tlb_cache_waddr] <= 1'b1;
    end

    // In cooperative mode, invalidate the whole cache
    // when any minion notifies an invalidation
    if (coop_mode_reg & |tlb_invalidated) begin
      tlb_cache_valid <= '0;
    end else if (~coop_mode_reg) begin
      // Otherwise, invalidate only entries for the corresponding min_id
      for (integer i = 0; i < NR_MINIONS; i++) begin
        if (tlb_invalidated[i]) begin
          tlb_cache_valid[i * ENTRIES_PER_MIN +: ENTRIES_PER_MIN] <= '0;
        end
      end
    end
  end
end

// Select cache read address
assign tlb_cache_raddr = tlb_index(req_min_id, req_data.vpn, vmspagesize, coop_mode_reg);

// Check cache hit
// If write permission and privilege mode is OK,
// it's only an actual store hit if the dirty bit is set
//assign tlb_cache_hit = tlb_cache_valid[tlb_cache_raddr] && vm_enabled && (tlb_cache_rtag == req_tag) && (req_data.store ? tlb_cache_rdata.dirty | ~w_perm_ok : 1'b1);
assign tlb_cache_hit = tlb_cache_valid[tlb_cache_raddr] && vm_enabled && (tlb_cache_rtag == req_tag) && (tlb_cache_rdata.expected_ex_mode ^ (privilege_mode != `CSR_PRV_M));
assign tlb_miss = vm_enabled && ~tlb_cache_hit;

// Permission checks
// -----------------
// Check privilege mode and permission properties
assign priv_ok = privilege_mode == `CSR_PRV_U ? tlb_cache_rdata.u   : // If privilege mode is user, privilege is OK when page is accessible to user mode
                 req_data.status.sum & !req_data.instruction ? 1'b1 : // If privilege mode is not user mode, privilege is always OK when SUM is enabled and not fetching instructions
                                                ~tlb_cache_rdata.u;   // Otherwise, privilege is OK when page is not accessible to user mode
assign w_perm_ok = priv_ok & tlb_cache_rdata.sw;
// Read permission to readable page or read permission to executable page (only if mxr=1)
assign r_perm_ok = priv_ok & (tlb_cache_rdata.sr | (req_data.status.mxr & tlb_cache_rdata.sx));
assign x_perm_ok = priv_ok & tlb_cache_rdata.sx;

// Software-managed Access/Dirty bit update
// Store that hits in a TLB entry with D=0, or valid leaf PTE response from the PTW with A=0.
assign tlb_xcpt_accessed = ~tlb_cache_rdata.access;
assign tlb_xcpt_dirty    = ~tlb_cache_rdata.dirty & req_data.store;

// Response with the physical bits
// -------------------------------
assign resp_data.miss = tlb_miss;
assign resp_data.fill_pending = state != `TLB_S_READY;

always_comb begin
  // If virtual memory is disabled, TLB is a passthrough from VPN to PPN
  if (!vm_enabled) begin
    resp_data.ppn = req_data.vpn[`PA_TRANS_RANGE];
  end else begin
    // Read cache data
    resp_data.ppn = tlb_cache_rdata.ppn;
  end
end

// Exceptions
// Address does not have correct privilege and/or permissions
assign resp_data.xcpt_ld = ((~r_perm_ok | tlb_xcpt_accessed) & tlb_cache_hit) | invalid_address;
assign resp_data.xcpt_st = ((~w_perm_ok | tlb_xcpt_dirty) & tlb_cache_hit) | invalid_address;
assign resp_data.xcpt_if = ((~x_perm_ok | tlb_xcpt_accessed) & tlb_cache_hit) | invalid_address;
assign resp_data.access_fault = (tlb_cache_rdata.ptw_access_fault & tlb_cache_hit);

endmodule

