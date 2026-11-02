// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

`include "soc.vh"

module icache_micro_cache #(
  parameter ID            = 0,
  parameter NR_MINIONS    = 8,
  parameter NR_MINIONS_L  = (NR_MINIONS == 1) ? 1 : $clog2(NR_MINIONS)
) (
  // System signals
  input  logic                                     clock,
  input  logic                                     reset,
  // ESRs
  input  icache_prefetch_conf_t                    esr_prefetch_conf,
  input  logic                                     esr_prefetch_start,
  output logic                                     esr_prefetch_done,
  input  esr_mprot_t                               esr_mprot,
  input  tlb_entry_type                            esr_vmspagesize,
  input  logic                                     esr_bypass_icache,
  input  logic                                     esr_shire_coop_mode,
  // Request port
  output logic                                     f0_req_ready,
  input  logic                                     f0_req_valid,
  input  frontend_icache_req                       f0_req,
  input  logic [NR_MINIONS_L-1:0]                  f0_req_min_id,
  // Response
  output logic                                     f4_resp_valid,
  output logic                                     f4_resp_miss,
  output icache_frontend_resp                      f4_resp,
  output logic                                     f5_resp_fill_done,
  // Flush control
  input  logic                                     f0_flush_data,
  // Request to L1 tag array
  input  logic                                     f0_l1_miss_req_ready,
  output logic                                     f0_l1_miss_req_valid,
  output logic [`PA_RANGE]                         f0_l1_miss_req_addr,
  // Response from L1
  input  logic                                     f0_l1_miss_resp_early_valid,
  input  logic                                     f0_l1_miss_resp_valid,
  input  logic [`ICACHE_BLOCK_BITS-1:0]            f0_l1_miss_resp_data,
  input  logic                                     f0_l1_miss_resp_ecc_err,
  input  logic                                     f0_l1_miss_resp_l2_err,
  // TLB/PTW control
  input  minion_satp_info [NR_MINIONS-1:0]         satp_info,
  input  minion_satp_info [NR_MINIONS-1:0]         matp_info,
  input  logic [NR_MINIONS-1:0]                    tlb_invalidate,
  // PTW request
  output minion_ptw_req                            ptw_req_data,
  output logic                                     ptw_req_valid,
  input  logic                                     ptw_req_ready,
  output logic                                     ptw_invalidate,
  // PTW response
  input  logic                                     ptw_resp_valid,
  input  minion_ptw_pte                            ptw_resp_data,
  // APB access
  input  logic [`ICACHE_DBG_UCACHE_ADDR_WIDTH-1:0] apb_paddr,
  input  logic                                     apb_pwrite,
  input  logic                                     apb_psel,
  input  logic                                     apb_penable,
  input  logic [`bpam_shire_apb_data_width-1:0]    apb_pwdata,
  output logic                                     apb_pready,
  output logic [`bpam_shire_apb_data_width-1:0]    apb_prdata,
  output logic                                     apb_pslverr,
  // Output debug signals going to Status Monitor
  output icache_dbg_sm_t                           dbg_sm_signals
  );

  // INTERNAL DECLARATIONS
  logic                                    f1_bypass_icache;
  logic                                    f2_bypass_icache;
  logic                                    f3_bypass_icache;
  logic                                    f1_is_prefetch;
  logic                                    f2_is_prefetch;
  logic                                    f3_is_prefetch;
  logic                                    f2_disable_l0_access;
  logic [NR_MINIONS_L-1:0]                 f0_req_min_id_pipe;
  frontend_icache_req                      f0_req_pipe;
  logic                                    f0_req_pipe_valid;
  logic                                    f1_valid; // Request valid in F1
  logic [NR_MINIONS_L-1:0]                 f1_min_id;
  icache_tlb_req                           f1_tlb_req_data; // TLB request data
  icache_tlb_resp                          f1_tlb_resp_data; // TLB response data in F1
  logic                                    f2_tlb_fill_done; // TLB fill finished
  logic                                    f2_valid; // Request valid in F2
  logic [`PA_RANGE]                        f2_paddr; // PC Physical address in F2
  icache_tlb_resp                          f2_tlb_resp_data; // TLB response data in F2
  logic [`ICACHE_MICRO_TAG_RANGE]          f2_tag; // Tag in F2
  logic                                    f2_hit; // Valid tag hit in F2
  logic                                    f2_miss; // Valid tag miss in F2
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]     f2_victim; // One-hot victim array
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]     f2_hit_array; // Hit array with the valid entries in F2
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]     f3_hit_array; // Hit array with the valid entries in F3
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]     f2_access_victim_array; // Accessed victim array due to a miss
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]     f2_write_victim_array; // Written victim array after a miss response
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]     f2_valid_hit_array; // Valid hit array
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]     f2_access_way_array; // Last ways accessed
  logic                                    f3_valid; // Valid transaction in F3 stage
  logic                                    f3_hit; // Hit in the F3 stage
  logic                                    f3_tlb_miss; // TLB miss in F3
  logic [`ICACHE_BLOCK_BITS-1:0]           f3_read_data; // Read data for F3 stage
  logic                                    f3_read_ecc_err; // Read ECC error in F3 stage
  logic                                    f3_read_l2_err; // Read L2 error in F3 stage
  logic                                    f2_page_fault; // Page fault exception found in TLB in F2 stage
  logic                                    f3_page_fault; // Page fault exception found in TLB in F3 stage
  logic                                    f2_access_fault; // Access fault exception found in TLB or PMA in F2 stage
  logic                                    f3_access_fault; // Access fault exception found in TLB or PMA in F3 stage
  logic                                    f3_cacheable; // Fetch block is in cacheable region in F3 stage
  logic                                    f2_bypass_hit; // Tag hit with bypass data
  logic [`ICACHE_DBG_UTAG_ADDR_WIDTH-1:0]  utag_apb_paddr;
  logic                                    utag_apb_pwrite;
  logic                                    utag_apb_psel;
  logic                                    utag_apb_penable;
  logic [`bpam_shire_apb_data_width-1:0]   utag_apb_pwdata;
  logic                                    utag_apb_pready;
  logic [`bpam_shire_apb_data_width-1:0]   utag_apb_prdata;
  logic                                    utag_apb_pslverr;
  logic [`ICACHE_DBG_UDATA_ADDR_WIDTH-1:0] udata_err_apb_paddr;
  logic                                    udata_err_apb_pwrite;
  logic                                    udata_apb_psel;
  logic                                    err_apb_psel;
  logic                                    udata_apb_penable;
  logic                                    err_apb_penable;
  logic [`bpam_shire_apb_data_width-1:0]   udata_err_apb_pwdata;
  logic                                    udata_err_apb_pready;
  logic [`bpam_shire_apb_data_width-1:0]   udata_err_apb_prdata;
  logic                                    udata_err_apb_pslverr;

  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // F0 Stage
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  icache_prefetch_state                f0_prefetch_state, f0_prefetch_state_next; // Prefetch FSM state
  logic [2:0]                          f0_prefetch_prereq_cnt, f0_prefetch_prereq_cnt_next;
  icache_prefetch_miss_nomh_state      f0_prefetch_miss_nomh_state, f0_prefetch_miss_nomh_state_next;
  logic [3:0]                          f0_prefetch_miss_nomh_cnt, f0_prefetch_miss_nomh_cnt_next;
  frontend_icache_req                  f0_prefetch_req, f0_prefetch_req_next; // Prefetch request
  logic [`ICACHE_PREFETCH_LINES_RANGE] f0_prefetch_lines, f0_prefetch_lines_next; // Prefetch pending lines - 1
  logic                                f0_prefetch_req_valid, f0_prefetch_req_valid_next; // Prefetch request is valid
  logic                                f0_prefetch_req_ready; // Prefetch request can be accepted
  logic                                f0_prefetch_req_access; // Prefetch request accesses pipeline
  logic                                f0_prefetch_load_new_req;
  logic                                f0_prefetch_done_next;
  icache_miss_state                    f0_miss_state, f0_miss_state_next; // Miss FSM state
  logic [`PA_RANGE]                    f0_miss_addr; // Address for the miss request
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0] f0_miss_victim; // One-hot victim array for the miss request
  logic                                f0_miss_bypass_icache;
  logic                                f0_miss_is_prefetch;
  logic                                f0_miss_disable_l0_access;

  //         CLK    RST    EN                        DOUT                         DIN                               DEF
  `RST_FF   (clock, reset,                           f0_prefetch_state,           f0_prefetch_state_next,           icache_prefetch_state_Idle)
  `RST_FF   (clock, reset,                           f0_prefetch_prereq_cnt,      f0_prefetch_prereq_cnt_next,      '0)
  `RST_FF   (clock, reset,                           f0_prefetch_miss_nomh_state, f0_prefetch_miss_nomh_state_next, icache_prefetch_miss_nomh_state_NotPending)
  `RST_FF   (clock, reset,                           f0_prefetch_miss_nomh_cnt,   f0_prefetch_miss_nomh_cnt_next,   '0)
  `EN_FF    (clock,        f0_prefetch_load_new_req, f0_prefetch_req,             f0_prefetch_req_next)
  `EN_FF    (clock,        f0_prefetch_load_new_req, f0_prefetch_lines,           f0_prefetch_lines_next)
  `RST_FF   (clock, reset,                           f0_prefetch_req_valid,       f0_prefetch_req_valid_next,       1'b0)
  `RST_FF   (clock, reset,                           esr_prefetch_done,           f0_prefetch_done_next,            1'b1)
  `RST_FF   (clock, reset,                           f0_miss_state,               f0_miss_state_next,               icache_miss_state_Ready)
  `EN_FF    (clock,        f2_miss,                  f0_miss_addr,                f2_paddr)
  `EN_FF    (clock,        f2_miss,                  f0_miss_victim,              f2_victim)
  `EN_FF    (clock,        f2_miss,                  f0_miss_bypass_icache,       f2_bypass_icache)
  `EN_FF    (clock,        f2_miss,                  f0_miss_is_prefetch,         f2_is_prefetch)
  `EN_FF    (clock,        f2_miss,                  f0_miss_disable_l0_access,   f2_disable_l0_access)

  // //////////////////////////////////////////////////////////////////////////////
  // FSM for prefetching service
  // Prefetch N consecutive cachelines starting from initial VA
  // //////////////////////////////////////////////////////////////////////////////
  always_comb begin
    f0_prefetch_state_next      = f0_prefetch_state;
    f0_prefetch_prereq_cnt_next = f0_prefetch_prereq_cnt;
    f0_prefetch_load_new_req    = 1'b0;
    f0_prefetch_done_next       = esr_prefetch_done;

    // In case of a start pulse move to Request (even if FSM is not idle)
    // If a previous prefetch request was in progress, it is cancelled
    // and FSM immediately starts working on the most recent request
    if (esr_prefetch_start) begin
      f0_prefetch_state_next = icache_prefetch_state_Request;
      f0_prefetch_load_new_req = 1'b1;
      f0_prefetch_done_next = 1'b1;
    end else if (f0_prefetch_state == icache_prefetch_state_Request) begin
      // Notify that start pulse was received with a negative edge of the
      // done signal
      f0_prefetch_done_next = 1'b0;

      // When prefetch request is accepted go check tag hit
      if(f0_prefetch_req_access)
        f0_prefetch_state_next = icache_prefetch_state_Check_Hit;
    end else if (f0_prefetch_state == icache_prefetch_state_Check_Hit) begin
      if (f2_valid & f2_is_prefetch) begin
        // If miss is accepted, wait for fill to come back
        if (f2_miss)
          f0_prefetch_state_next = icache_prefetch_state_Fill_Wait;
        // If there is an exception, then move to the next VA
        else if (f2_page_fault || f2_access_fault) begin
          f0_prefetch_state_next = icache_prefetch_state_FillDone_Wait;
          f0_prefetch_load_new_req = 1'b1;
        end
        // Otherwise, retry the same request
        else
          f0_prefetch_state_next = icache_prefetch_state_FillDone_Wait;
      end
    end else if (f0_prefetch_state == icache_prefetch_state_Fill_Wait) begin
      // Wait for fill to come back
      if (f0_l1_miss_resp_valid) begin
        // If all lines have been processed, finish
        if (f0_prefetch_lines == '0) begin
          f0_prefetch_state_next = icache_prefetch_state_Idle;
          // Notify that prefetch finished with a positive edge of the
          // done signal
          f0_prefetch_done_next = 1'b1;
        end else begin
          // Otherwise, move to the next VA
          f0_prefetch_state_next = icache_prefetch_state_FillDone_Wait;
          f0_prefetch_load_new_req = 1'b1;
        end
      end
    end else if (f0_prefetch_state == icache_prefetch_state_FillDone_Wait) begin
      // First, wait for fill done to be sent to the Minions
      if (f5_resp_fill_done) begin
        f0_prefetch_prereq_cnt_next = '0;
        f0_prefetch_state_next = icache_prefetch_state_PreReq_Pause;
      end
    end else if (f0_prefetch_state == icache_prefetch_state_PreReq_Pause) begin
      // After that, leave a certain number of cycles for Minions to retry
      // before sending a new prefetch request
      f0_prefetch_prereq_cnt_next = f0_prefetch_prereq_cnt + 1'b1;

      if (f0_prefetch_prereq_cnt == '1)
        f0_prefetch_state_next = icache_prefetch_state_Request;
    end
  end

  // FSM tracking misses that are not attended to (since the MH is already busy)
  always_comb
  begin
    f0_prefetch_miss_nomh_state_next = f0_prefetch_miss_nomh_state;
    f0_prefetch_miss_nomh_cnt_next   = f0_prefetch_miss_nomh_cnt;

    case (f0_prefetch_miss_nomh_state)

      // No miss that was not attended to is pending
      icache_prefetch_miss_nomh_state_NotPending:
      begin
        // A miss not attended to is detected 
        if (f2_valid && !f2_hit && !f2_miss && !f2_is_prefetch && !f2_page_fault && !f2_access_fault)
          f0_prefetch_miss_nomh_state_next = icache_prefetch_miss_nomh_state_FillDone_Wait;
      end

      // Wait for fill done to be notified
      icache_prefetch_miss_nomh_state_FillDone_Wait:
      begin
        if (f5_resp_fill_done)
        begin
          f0_prefetch_miss_nomh_cnt_next = '0;
          f0_prefetch_miss_nomh_state_next = icache_prefetch_miss_nomh_state_Req_Wait;
        end
      end

      // Then, wait for a new request to be received and clear the pending status
      // (if, after a certain number of cycles, no request is received, pending status is also cleared)
      icache_prefetch_miss_nomh_state_Req_Wait:
      begin
        f0_prefetch_miss_nomh_cnt_next = f0_prefetch_miss_nomh_cnt + 1'b1;

        if (f0_req_valid || (f0_prefetch_miss_nomh_cnt == '1))
          f0_prefetch_miss_nomh_state_next = icache_prefetch_miss_nomh_state_NotPending;
      end

      default:
      begin
        f0_prefetch_miss_nomh_state_next = icache_prefetch_miss_nomh_state_NotPending;
      end

    endcase
  end

  // Prefetch request
  always_comb begin
    f0_prefetch_req_next = '0;

    if (esr_prefetch_start) begin
      f0_prefetch_req_next.vm_status.prv      = esr_prefetch_conf.prv; // Other VM status fields are forced to 0
      f0_prefetch_req_next.addr[`VA_RANGE_CA] = esr_prefetch_conf.start_addr;
      f0_prefetch_req_next.addr[`VA_EXT_MSB]  = esr_prefetch_conf.start_addr[`VA_MSB];
      f0_prefetch_lines_next                  = esr_prefetch_conf.num_lines;
    end else begin
      f0_prefetch_req_next.vm_status.prv          = f0_prefetch_req.vm_status.prv;
      // If overflow, the 2 MSBs will be different => will end up with msb_err to TLB
      f0_prefetch_req_next.addr[`VA_RANGE_CA_EXT] = f0_prefetch_req.addr[`VA_RANGE_CA] + 1'b1;
      f0_prefetch_lines_next                      = f0_prefetch_lines - 1'b1;
    end

    // Prefetch request is only qualified if there are no pending misses that were not attended to
    f0_prefetch_req_valid_next = (f0_prefetch_state_next == icache_prefetch_state_Request) && (f0_prefetch_miss_nomh_state == icache_prefetch_miss_nomh_state_NotPending);
  end

  // The prefetch FSM will insert tag lookup requests when no minion is using the icache
  assign f0_prefetch_req_ready = ~f0_req_valid;
  assign f0_prefetch_req_access = f0_prefetch_req_valid & f0_prefetch_req_ready;

  assign f0_req_ready = 1'b1;

  // //////////////////////////////////////////////////////////////////////////////
  // FSM to handle a miss
  // //////////////////////////////////////////////////////////////////////////////
  always_comb begin
    f0_miss_state_next = f0_miss_state;

    // Ready state
    if(f0_miss_state == icache_miss_state_Ready) begin
      // In case of miss move to request
      if (f2_miss)
      f0_miss_state_next = icache_miss_state_Request;
    end
    // Sending a request
    else if(f0_miss_state == icache_miss_state_Request) begin
      // Request gets accepted
      if (f0_l1_miss_req_ready)
      f0_miss_state_next = icache_miss_state_Fill_Wait;
    end else begin
    // Waiting for a fill to come back
    // if (f0_miss_state == icache_miss_state_Fill_Wait)
      if (f0_l1_miss_resp_valid)
      f0_miss_state_next = icache_miss_state_Ready;
    end
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Miss request to L1 tag array
  // //////////////////////////////////////////////////////////////////////////////
  assign f0_l1_miss_req_valid = f0_miss_state == icache_miss_state_Request;
  assign f0_l1_miss_req_addr  = f0_miss_addr;

  // //////////////////////////////////////////////////////////////////////////////
  // APB access
  // //////////////////////////////////////////////////////////////////////////////

  // Accesses to udata and error flag regions will be combined into a single bus
  assign udata_err_apb_paddr  = apb_paddr[`ICACHE_DBG_UDATA_ADDR_START +: `ICACHE_DBG_UDATA_ADDR_WIDTH];
  assign udata_err_apb_pwrite = apb_pwrite;
  assign udata_apb_psel       = apb_psel    && (apb_paddr[`ICACHE_DBG_UCACHE_BLOCK_ADDR_RANGE] == `ICACHE_DBG_UDATA_ADDR_REGION);
  assign err_apb_psel         = apb_psel    && (apb_paddr[`ICACHE_DBG_UCACHE_BLOCK_ADDR_RANGE]    == `ICACHE_DBG_ERR_BLOCK_ADDR_REGION)
      && (apb_paddr[`ICACHE_DBG_UCACHE_SUBBLOCK_ADDR_RANGE] == `ICACHE_DBG_ERR_SUBBLOCK_ADDR_REGION);
  assign udata_apb_penable    = apb_penable && (apb_paddr[`ICACHE_DBG_UCACHE_BLOCK_ADDR_RANGE] == `ICACHE_DBG_UDATA_ADDR_REGION);
  assign err_apb_penable      = apb_penable && (apb_paddr[`ICACHE_DBG_UCACHE_BLOCK_ADDR_RANGE]    == `ICACHE_DBG_ERR_BLOCK_ADDR_REGION)
      && (apb_paddr[`ICACHE_DBG_UCACHE_SUBBLOCK_ADDR_RANGE] == `ICACHE_DBG_ERR_SUBBLOCK_ADDR_REGION);
  assign udata_err_apb_pwdata = apb_pwdata;
  assign utag_apb_paddr       = apb_paddr[`ICACHE_DBG_UTAG_ADDR_START +: `ICACHE_DBG_UTAG_ADDR_WIDTH];
  assign utag_apb_pwrite      = apb_pwrite;
  assign utag_apb_psel        = apb_psel    && (apb_paddr[`ICACHE_DBG_UCACHE_BLOCK_ADDR_RANGE]    == `ICACHE_DBG_UTAG_BLOCK_ADDR_REGION)
      && (apb_paddr[`ICACHE_DBG_UCACHE_SUBBLOCK_ADDR_RANGE] == `ICACHE_DBG_UTAG_SUBBLOCK_ADDR_REGION);
  assign utag_apb_penable     = apb_penable && (apb_paddr[`ICACHE_DBG_UCACHE_BLOCK_ADDR_RANGE]    == `ICACHE_DBG_UTAG_BLOCK_ADDR_REGION)
      && (apb_paddr[`ICACHE_DBG_UCACHE_SUBBLOCK_ADDR_RANGE] == `ICACHE_DBG_UTAG_SUBBLOCK_ADDR_REGION);
  assign utag_apb_pwdata      = apb_pwdata;

  // Combine ready, read data and error signals
  assign apb_pready = udata_err_apb_pready | utag_apb_pready;
  assign apb_prdata = udata_err_apb_prdata & {`bpam_shire_apb_data_width{udata_err_apb_pready}}
      | utag_apb_prdata      & {`bpam_shire_apb_data_width{utag_apb_pready}};
  assign apb_pslverr = udata_err_apb_pslverr | utag_apb_pslverr;

   // Lint
   wire apb_unused_ok = &{
     `ifndef ET_ASCENT_LINT
      1'b0,
      `endif
      udata_apb_penable,
      err_apb_penable
   };

  // //////////////////////////////////////////////////////////////////////////////
  // Udata array debug access
  // //////////////////////////////////////////////////////////////////////////////
  icache_data_dbg_state_t                            udata_dbg_state, udata_dbg_state_next;
  logic [`ICACHE_DBG_UDATA_MEM_CHUNK_ADDR_WIDTH-1:0] udata_dbg_mem_chunk, udata_dbg_mem_chunk_next;
  logic [`ICACHE_MICRO_CACHE_SIZE-1:0]               udata_dbg_mem_addr_dec, udata_dbg_mem_addr_dec_next;
  logic                                              udata_dbg_mem_err, udata_dbg_mem_err_next;
  logic                                              udata_dbg_write_en, udata_dbg_write_en_next;
  logic [(`ICACHE_BLOCK_BITS+2)-1:0]                 udata_dbg_write_data, udata_dbg_write_data_next;
  logic                                              udata_dbg_write_ready;
  logic                                              udata_dbg_read_en, udata_dbg_read_en_next;
  logic [(`ICACHE_BLOCK_BITS+2)-1:0]                 udata_dbg_read_data;
  logic                                              udata_dbg_read_ready;
  logic [`bpam_shire_apb_data_width-1:0]             udata_err_apb_prdata_next;
  logic                                              udata_err_apb_pready_next;

  // CLK    RST    EN                                                 DOUT                    DIN                        DEF
  `RST_FF (clock, reset,                                                    udata_dbg_state,        udata_dbg_state_next,      icache_data_dbg_state_Idle)
  `EN_FF  (clock,        udata_dbg_read_en_next,                            udata_dbg_mem_chunk,    udata_dbg_mem_chunk_next)
  `EN_FF  (clock,        udata_dbg_read_en_next,                            udata_dbg_mem_addr_dec, udata_dbg_mem_addr_dec_next)
  `EN_FF  (clock,        udata_dbg_read_en_next,                            udata_dbg_mem_err,      udata_dbg_mem_err_next)
  `RST_FF (clock, reset,                                                    udata_dbg_write_en,     udata_dbg_write_en_next,   1'b0)
  `EN_FF  (clock,        udata_dbg_write_en_next,                           udata_dbg_write_data,   udata_dbg_write_data_next)
  `RST_FF (clock, reset,                                                    udata_dbg_read_en,      udata_dbg_read_en_next,    1'b0)
  `EN_FF  (clock,        udata_err_apb_pready_next & ~udata_err_apb_pwrite, udata_err_apb_prdata,   udata_err_apb_prdata_next)
  `RST_FF (clock, reset,                                                    udata_err_apb_pready,   udata_err_apb_pready_next, 1'b0)

  // FSM
  always_comb begin
    udata_dbg_state_next      = udata_dbg_state;
    udata_dbg_write_en_next   = udata_dbg_write_en;
    udata_dbg_read_en_next    = udata_dbg_read_en;
    udata_err_apb_pready_next = udata_err_apb_pready;

    // Idle
    if (udata_dbg_state == icache_data_dbg_state_Idle) begin
      // Generate and store read request
      // Combine accesses to udata and error flag regions into bus going to udata array debug interface
      // If it is a write access, we first need to read data to overwrite selected chunk
      if (udata_apb_psel || err_apb_psel) begin
        udata_dbg_state_next   = icache_data_dbg_state_WaitReadReady;
        udata_dbg_read_en_next = 1'b1;
      end
    end else if (udata_dbg_state == icache_data_dbg_state_WaitReadReady) begin
    // Wait for read request to be accepted
      if (udata_dbg_read_ready) begin
        udata_dbg_read_en_next = 1'b0;
        if (udata_err_apb_pwrite) begin
          // If it is a write access, overwrite data chunk
          udata_dbg_state_next    = icache_data_dbg_state_WaitWriteReady;
          udata_dbg_write_en_next = 1'b1;
        end else begin
          // If it is a read access, send back read data
          udata_dbg_state_next      = icache_data_dbg_state_Done;
          udata_err_apb_pready_next = 1'b1;
        end
      end
    end else if (udata_dbg_state == icache_data_dbg_state_WaitWriteReady) begin
    // Wait for write request to be accepted
      if (udata_dbg_write_ready) begin
        udata_dbg_write_en_next   = 1'b0;
        // Acknowledge write
        udata_dbg_state_next      = icache_data_dbg_state_Done;
        udata_err_apb_pready_next = 1'b1;
      end
    end else if (udata_dbg_state == icache_data_dbg_state_Done) begin
    // Disable pready signal and go to idle
      udata_dbg_state_next      = icache_data_dbg_state_Idle;
      udata_err_apb_pready_next = 1'b0;
    end
  end

  // Decode chunk and entry from APB address
  assign udata_dbg_mem_chunk_next    = udata_err_apb_paddr[`ICACHE_DBG_UDATA_MEM_CHUNK_ADDR_WIDTH-1:0];
  assign udata_dbg_mem_addr_dec_next = 1'b1 << udata_err_apb_paddr[`ICACHE_DBG_UDATA_ADDR_WIDTH-1 -: `ICACHE_MICRO_CACHE_ADWIDTH];
  assign udata_dbg_mem_err_next      = err_apb_psel;

  // Take debug write data from memory data out
  // and overwrite selected chunk
  always_comb begin
    udata_dbg_write_data_next = udata_dbg_read_data;
    if (udata_dbg_mem_err)
      udata_dbg_write_data_next[`ICACHE_BLOCK_BITS +: 2] = udata_err_apb_pwdata[1:0];
    else
    udata_dbg_write_data_next[udata_dbg_mem_chunk*`bpam_shire_apb_data_width +: `bpam_shire_apb_data_width] = udata_err_apb_pwdata;
  end

  // Take debug read data from memory data out
  assign udata_err_apb_prdata_next = udata_dbg_mem_err ? (`bpam_shire_apb_data_width)'(udata_dbg_read_data[`ICACHE_BLOCK_BITS +: 2])
      : udata_dbg_read_data[udata_dbg_mem_chunk*`bpam_shire_apb_data_width +: `bpam_shire_apb_data_width];

  assign udata_err_apb_pslverr = 1'b0;

  // //////////////////////////////////////////////////////////////////////////////
  // Connect output debug signals
  // //////////////////////////////////////////////////////////////////////////////
  always_comb begin
    dbg_sm_signals = '0;

    dbg_sm_signals.ucache_f0_prefetch_state = f0_prefetch_state;
    dbg_sm_signals.ucache_f0_miss_state[ID] = f0_miss_state;
    dbg_sm_signals.ucache_f2_valid[ID]      = f2_valid;
    dbg_sm_signals.ucache_f2_hit_array[ID]  = f2_hit_array;
    dbg_sm_signals.ucache_f2_paddr[ID]      = f2_paddr[`PA_RANGE_CA];
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Micro cache request pipeline
  // //////////////////////////////////////////////////////////////////////////////

  // Insert prefetch requests
  // The minion id used by the prefetch service is always 0
  // (VM configuration should be the same for all the minions)
  assign f0_req_min_id_pipe = f0_prefetch_req_access ? '0              : f0_req_min_id;
  assign f0_req_pipe        = f0_prefetch_req_access ? f0_prefetch_req : f0_req;
  assign f0_req_pipe_valid  = f0_req_valid || f0_prefetch_req_valid;

  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // F1 Stage
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  frontend_icache_req f1_req;

  // CLK    RST    EN                 DOUT              DIN                DEF
  `RST_FF(clock, reset,                    f1_valid,         f0_req_pipe_valid, 1'b0)
  `EN_FF (clock,        f0_req_pipe_valid, f1_min_id,        f0_req_min_id_pipe)
  `EN_FF (clock,        f0_req_pipe_valid, f1_req,           f0_req_pipe)
  `EN_FF (clock,        f0_req_pipe_valid, f1_bypass_icache, esr_bypass_icache)
  `EN_FF (clock,        f0_req_pipe_valid, f1_is_prefetch,   f0_prefetch_req_access)

  // //////////////////////////////////////////////////////////////////////////////
  // TLB that converts addresses from virtual to physical
  // //////////////////////////////////////////////////////////////////////////////
  logic f2_tlb_fill_was_pending; // TLB fill was pending in previous cycle

  // Generate TLB request
  assign f1_tlb_req_data = '{ status      : f1_req.vm_status,
                            vpn         : f1_req.addr[`VA_TRANS_RANGE],
                            passthrough : 1'b0,
                            msb_err     : f1_req.addr[`VA_EXT_MSB] ^ f1_req.addr[`VA_MSB]
  };

  // Instantiate TLB shared among all the minions
  icache_tlb_array #(
    .ENTRIES             ( `ICACHE_TLB_ENTRIES ),
    .NR_MINIONS          ( NR_MINIONS          )
  ) tlb_array (
    // System signals
    .clock               ( clock               ),
    .reset               ( reset               ),
    // ESRs
    .esr_vmspagesize     ( esr_vmspagesize     ),
    .esr_shire_coop_mode ( esr_shire_coop_mode ),
    // Request to the TLB
    .req_min_id          ( f1_min_id           ),
    .req_data            ( f1_tlb_req_data     ),
    .req_valid           ( f1_valid            ),
    // Response with the physical bits
    .resp_data           ( f1_tlb_resp_data    ),
    // TLB/PTW control
    .satp_info           ( satp_info           ),
    .matp_info           ( matp_info           ),
    .tlb_invalidate      ( tlb_invalidate      ),
    // PTW request
    .ptw_req_data        ( ptw_req_data        ),
    .ptw_req_valid       ( ptw_req_valid       ),
    .ptw_req_ready       ( ptw_req_ready       ),
    .ptw_invalidate      ( ptw_invalidate      ),
    // PTW response
    .ptw_resp_valid      ( ptw_resp_valid      ),
    .ptw_resp_data       ( ptw_resp_data       )
  );

  // CLK    RST    DOUT                     DIN                            DEF
  `RST_FF (clock, reset, f2_tlb_fill_was_pending, f1_tlb_resp_data.fill_pending, 1'b0)

  // Notify that TLB fill finished
  assign f2_tlb_fill_done = f2_tlb_fill_was_pending && !f1_tlb_resp_data.fill_pending;

  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // F2 Stage
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  frontend_icache_req             f2_req;
  logic                           f2_any_tag_hit; // There was any hit in the tags in F2
  logic                           f2_tag_array_miss;
  logic                           f0_tag_array_wr_early_valid;
  logic                           f0_tag_array_wr_valid;
  logic [`ICACHE_MICRO_TAG_RANGE] f0_tag_array_wr_tag;
  icache_pma_resp                 f2_pma_resp_data; // PMA response data in F2

  // CLK    RST    EN        DOUT              DIN               DEF
  `RST_FF    (clock, reset,           f2_valid,         f1_valid,         1'b0)
  `EN_FF     (clock,        f1_valid, f2_req,           f1_req)
  `RST_EN_FF (clock, reset, f1_valid, f2_tlb_resp_data, f1_tlb_resp_data, '0)
  `EN_FF     (clock,        f1_valid, f2_bypass_icache, f1_bypass_icache)
  `EN_FF     (clock,        f1_valid, f2_is_prefetch,   f1_is_prefetch)

  // Gets the PA from the TLB response
  assign f2_paddr = { f2_tlb_resp_data.ppn, f2_req.addr[`PA_UNTRANS_SIZE-1:0] };

  // Check page and access faults
  assign f2_page_fault   = f2_tlb_resp_data.xcpt_if;
  assign f2_access_fault = (~f2_tlb_resp_data.miss & f2_pma_resp_data.access_fault) | f2_tlb_resp_data.access_fault;

  // Access to L0 micro cache is disabled if icache is bypassed or it is a prefetch request
  assign f2_disable_l0_access = f2_bypass_icache || f2_is_prefetch;

  // //////////////////////////////////////////////////////////////////////////////
  // Tag match
  // //////////////////////////////////////////////////////////////////////////////
  // Send tag to tag array
  assign f2_tag = f2_paddr[`ICACHE_MICRO_TAG_RANGE];

  // Indicate miss to tag array so that it invalidates victim
  // (except if access to L0 is disabled)
  assign f2_tag_array_miss = f2_miss & ~f2_disable_l0_access;

  // Write request to tag array
  assign f0_tag_array_wr_early_valid = f0_l1_miss_resp_early_valid;
  assign f0_tag_array_wr_valid       = f0_l1_miss_resp_valid & ~f0_miss_disable_l0_access;
  assign f0_tag_array_wr_tag         = f0_miss_addr[`ICACHE_MICRO_TAG_RANGE];

  icache_micro_tag_array micro_tag_array (
  // System signals
    .clock             ( clock                       ),
    .reset             ( reset                       ),
    // Read request
    .f2_rd_tag         ( f2_tag                      ),
    .f2_rd_hit_array   ( f2_hit_array                ),
    // Write request
    .f0_wr_early_valid ( f0_tag_array_wr_early_valid ),
    .f0_wr_valid       ( f0_tag_array_wr_valid       ),
    .f0_wr_victim      ( f0_miss_victim              ),
    .f0_wr_tag         ( f0_tag_array_wr_tag         ),
    // Miss indication
    .f2_miss           ( f2_tag_array_miss           ),
    .f2_miss_victim    ( f2_victim                   ),
    .f0_miss_state     ( f0_miss_state               ),
    // Flush control
    .f0_flush_data     ( f0_flush_data               ),
    // Debug access
    .apb_paddr         ( utag_apb_paddr              ),
    .apb_pwrite        ( utag_apb_pwrite             ),
    .apb_psel          ( utag_apb_psel               ),
    .apb_penable       ( utag_apb_penable            ),
    .apb_pwdata        ( utag_apb_pwdata             ),
    .apb_pready        ( utag_apb_pready             ),
    .apb_prdata        ( utag_apb_prdata             ),
    .apb_pslverr       ( utag_apb_pslverr            )
  );

  // If it is a prefetch request, disable hit in L0
  // If icache is bypassed, try hit with bypass data
  // Otherwise, take regular tag hit array
  assign f2_any_tag_hit = f2_is_prefetch   ? 1'b0
                        : f2_bypass_icache ? f2_bypass_hit
                        : |f2_hit_array;

  assign f2_hit         = f2_any_tag_hit && f2_valid;
  assign f2_miss        = !f2_any_tag_hit && f2_valid
                        && !f2_tlb_resp_data.miss // Check there wasn't a TLB miss
                        && !f2_page_fault // Check there wasn't a page fault
                        && !f2_access_fault // Check there wasn't an access fault
                        && (f0_miss_state == icache_miss_state_Ready); // Miss is accepted when miss FSM is ready

  // //////////////////////////////////////////////////////////////////////////////
  // LRU update
  // //////////////////////////////////////////////////////////////////////////////
  // Generate a valid hit array to update the victim
  assign f2_valid_hit_array = f2_hit_array & {`ICACHE_MICRO_CACHE_SIZE{f2_hit}};
  // Generate the accessed victim array due to a miss
  assign f2_access_victim_array = f2_victim & {`ICACHE_MICRO_CACHE_SIZE{f2_miss}};
  // Generate the accessed victim array when the miss response comes back
  assign f2_write_victim_array = f0_miss_victim & {`ICACHE_MICRO_CACHE_SIZE{f0_l1_miss_resp_valid}};
  // Update last accessed way. The update is done:
  // - Once per valid request if there is either a hit or an accepted miss
  // - When the accepted miss response is effectively cached
  // If access to L0 micro cache is disabled, LRU is not updated
  assign f2_access_way_array = (f2_valid_hit_array | f2_access_victim_array | f2_write_victim_array) & {`ICACHE_MICRO_CACHE_SIZE{~f2_disable_l0_access}};

  // LRU selector
  // Select a victim (a way to replace) based on LRU
  lru_sel #(
    .NUM_CLIENTS  ( `ICACHE_MICRO_CACHE_SIZE )
  ) lru (
    // System signals
    .clock        ( clock                    ),
    .reset        ( reset                    ),
    // Update
    .access_entry ( f2_access_way_array      ),
    // Victim
    .victim       ( f2_victim                )
  );

  // //////////////////////////////////////////////////////////////////////////////
  // PMA that checks permissions for physical addresses
  // //////////////////////////////////////////////////////////////////////////////

  icache_pma_unit pma_unit (
    // Request to the PMA
    .paddr          ( f2_paddr             ),
    .mprot          ( esr_mprot            ),
    // PTW info
    .ptw_prv        ( f2_req.vm_status.prv ),
    // Response with the permission checks
    .resp_data      ( f2_pma_resp_data     )
  );

  // //////////////////////////////////////////////////////////////////////////////
  // Flip-Flop to store request line when icache is bypassed
  // //////////////////////////////////////////////////////////////////////////////
  logic                           bypass_en;
  logic                           bypass_valid, bypass_valid_next;
  logic [`ICACHE_MICRO_TAG_RANGE] bypass_tag;
  logic [`ICACHE_BLOCK_BITS-1:0]  bypass_data;
  logic                           bypass_ecc_err;
  logic                           bypass_l2_err;

  // CLK    RST    EN         DOUT            DIN                DEF
  `RST_FF(clock, reset,            bypass_valid,   bypass_valid_next, 1'b0)
  `EN_FF (clock,        bypass_en, bypass_tag,     f0_miss_addr[`ICACHE_MICRO_TAG_RANGE])
  `EN_FF (clock,        bypass_en, bypass_data,    f0_l1_miss_resp_data)
  `EN_FF (clock,        bypass_en, bypass_ecc_err, f0_l1_miss_resp_ecc_err)
  `EN_FF (clock,        bypass_en, bypass_l2_err,  f0_l1_miss_resp_l2_err)

  assign bypass_en = f0_l1_miss_resp_valid & f0_miss_bypass_icache & ~f0_miss_is_prefetch;

  always_comb begin
    bypass_valid_next = bypass_valid;

    // When bypass is enabled and new data is loaded, validate it
    if (bypass_en)
      bypass_valid_next = 1'b1;
    // If bypass is disabled, invalidate bypass data
    else if (!f2_bypass_icache)
      bypass_valid_next = 1'b0;
  end

  // Compare tags with bypass tag
  // If tags are being written in this cycle, avoid hitting wit old data
  assign f2_bypass_hit = bypass_valid & ~bypass_en & (bypass_tag == f2_tag);

  // //////////////////////////////////////////////////////////////////////////////
  // Fill done pulse (either the TLB or data array fill)
  // //////////////////////////////////////////////////////////////////////////////
  logic f2_resp_fill_done;

  assign f2_resp_fill_done = f2_tlb_fill_done | f0_l1_miss_resp_valid;

  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // F3 Stage
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  logic [`ICACHE_CHUNK_ADDR_SIZE-1:0] f3_data_chunk;

  // CLK    RST    EN        DOUT              DIN                    DEF
  `RST_FF    (clock, reset,           f3_valid,         f2_valid,              1'b0)
  `EN_FF     (clock,        f2_valid, f3_data_chunk,    f2_paddr[`ICACHE_BLOCK_ADDR_SIZE-1 -: `ICACHE_CHUNK_ADDR_SIZE])
  `EN_FF     (clock,        f2_valid, f3_hit_array,     f2_hit_array)
  `RST_EN_FF (clock, reset, f2_valid, f3_hit,           f2_hit,                1'b0)
  `RST_EN_FF (clock, reset, f2_valid, f3_tlb_miss,      f2_tlb_resp_data.miss, 1'b0)
  `EN_FF     (clock,        f2_valid, f3_page_fault,    f2_page_fault)
  `EN_FF     (clock,        f2_valid, f3_access_fault,  f2_access_fault)
  `EN_FF     (clock,        f2_hit,   f3_cacheable,     f2_pma_resp_data.cacheable)
  `EN_FF     (clock,        f2_valid, f3_bypass_icache, f2_bypass_icache)
  `EN_FF     (clock,        f2_valid, f3_is_prefetch,   f2_is_prefetch)

  // //////////////////////////////////////////////////////////////////////////////
  // Micro cache data array
  // //////////////////////////////////////////////////////////////////////////////
  logic [(`ICACHE_BLOCK_BITS+2)-1:0] f3_data_array_rd_data;
  logic                              f0_data_array_wr_en;
  logic                              f0_data_array_wr_en_early;
  logic [(`ICACHE_BLOCK_BITS+2)-1:0] f0_data_array_wr_data;

  assign f0_data_array_wr_en       = f0_l1_miss_resp_valid & ~f0_miss_disable_l0_access;
  assign f0_data_array_wr_en_early = f0_l1_miss_resp_early_valid;
  assign f0_data_array_wr_data     = {f0_l1_miss_resp_l2_err,f0_l1_miss_resp_ecc_err,f0_l1_miss_resp_data};

  icache_micro_data_array #(
    .WIDTH              ( `ICACHE_BLOCK_BITS+2      ),
    .ENTRIES            ( `ICACHE_MICRO_CACHE_SIZE  )
  ) micro_data_array (
    // System signals
    .clock              ( clock                     ),
    // Read port request
    .f3_rd_en           ( f3_valid                  ),
    .f3_rd_addr_dec     ( f3_hit_array              ),
    .f3_rd_data         ( f3_data_array_rd_data     ),
    // Write port request
    .f0_wr_en           ( f0_data_array_wr_en       ),
    .f0_wr_en_early     ( f0_data_array_wr_en_early ),
    .f0_wr_addr_dec     ( f0_miss_victim            ),
    .f0_wr_data         ( f0_data_array_wr_data     ),
    // Debug access
    .dbg_addr_dec       ( udata_dbg_mem_addr_dec    ),
    .dbg_write_en       ( udata_dbg_write_en        ),
    .dbg_write_en_early ( udata_dbg_write_en_next   ),
    .dbg_write_data     ( udata_dbg_write_data      ),
    .dbg_write_ready    ( udata_dbg_write_ready     ),
    .dbg_read_en        ( udata_dbg_read_en         ),
    .dbg_read_data      ( udata_dbg_read_data       ),
    .dbg_read_ready     ( udata_dbg_read_ready      )
  );

  assign f3_read_data    = f3_data_array_rd_data[`ICACHE_BLOCK_BITS-1:0];
  assign f3_read_ecc_err = f3_data_array_rd_data[`ICACHE_BLOCK_BITS];
  assign f3_read_l2_err  = f3_data_array_rd_data[`ICACHE_BLOCK_BITS+1];

  // //////////////////////////////////////////////////////////////////////////////
  // Response to the minions
  // //////////////////////////////////////////////////////////////////////////////
  logic                f3_resp_valid;
  logic                f3_resp_miss;
  icache_frontend_resp f3_resp;

  // Disable response to minions if it is a prefetch request
  assign f3_resp_valid        = f3_valid & ~f3_is_prefetch;
  assign f3_resp_miss         = ~f3_hit | f3_tlb_miss;
  // data and cacheable fields are only valid if ~f3_resp_miss
  assign f3_resp.data         = f3_bypass_icache ? bypass_data[f3_data_chunk*`FE_FETCH_READ_SIZE +: `FE_FETCH_READ_SIZE]
     : f3_read_data[f3_data_chunk*`FE_FETCH_READ_SIZE +: `FE_FETCH_READ_SIZE];
  assign f3_resp.cacheable    = f3_cacheable;
  // Error fields (page_fault, access_fault, ecc_err and bus_err) are valid regardless of f3_resp_miss
  // - ecc_err and bus_err are actually only valid on hit, so we need to validate them with ~f3_resp_miss
  assign f3_resp.page_fault   = f3_page_fault;
  assign f3_resp.access_fault = f3_access_fault;
  assign f3_resp.ecc_err      = ~f3_resp_miss & (f3_bypass_icache ? bypass_ecc_err
      : f3_read_ecc_err);
  assign f3_resp.bus_err      = ~f3_resp_miss & (f3_bypass_icache ? bypass_l2_err
      : f3_read_l2_err);

  // //////////////////////////////////////////////////////////////////////////////
  // Fill done pulse (either the TLB or data array fill) in F3
  // //////////////////////////////////////////////////////////////////////////////
  logic f3_resp_fill_done;

  // CLK    RST    DOUT               DIN                DEF
  `RST_FF (clock, reset, f3_resp_fill_done, f2_resp_fill_done, 1'b0)

  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // F4 Stage
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////

  // //////////////////////////////////////////////////////////////////////////////
  // Response to the minions
  // //////////////////////////////////////////////////////////////////////////////

  //          CLK    RST    EN             DOUT           DIN            DEF
  `RST_FF    (clock, reset,                f4_resp_valid, f3_resp_valid, 1'b0)
  `RST_EN_FF (clock, reset, f3_resp_valid, f4_resp_miss,  f3_resp_miss,  1'b1)
  `EN_FF     (clock,        f3_resp_valid, f4_resp,       f3_resp)

  // //////////////////////////////////////////////////////////////////////////////
  // Fill done pulse (either the TLB or data array fill) in F4
  // //////////////////////////////////////////////////////////////////////////////
  logic f4_resp_fill_done;

  //       CLK    RST    DOUT               DIN                DEF
  `RST_FF (clock, reset, f4_resp_fill_done, f3_resp_fill_done, 1'b0)

  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // F5 Stage
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////
  // //////////////////////////////////////////////////////////////////////////////

  // //////////////////////////////////////////////////////////////////////////////
  // Fill done pulse (either the TLB or data array fill) in F5
  // //////////////////////////////////////////////////////////////////////////////

  //       CLK    RST    DOUT               DIN                DEF
  `RST_FF (clock, reset, f5_resp_fill_done, f4_resp_fill_done, 1'b0)

endmodule
