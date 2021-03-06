// Copyright (c) 2016-2019 Bluespec, Inc. All Rights Reserved.

//-
// CHERI modifications:
//     Copyright (c) 2019 Peter Rugg
//     All rights reserved.
//
//     This software was developed by SRI International and the University of
//     Cambridge Computer Laboratory (Department of Computer Science and
//     Technology) under DARPA contract HR0011-18-C-0016 ("ECATS"), as part of the
//     DARPA SSITH research programme.
//-

// Near_Mem_IFC is an abstraction of two alternatives: caches or TCM
// (TCM = Tightly Coupled Memory).  Both are memories that are
// 'near' the CPU (1-cycle access in common case).

// On the CPU side it directly services instruction fetches and DMem
// reads and writes.

// On the Fabric side it has one or two Client sub-interfaces and a
// Server sub-interface.  The Client sub-interfaces are used to
// pass-through, to the fabric, I/O requests, cache-fill/ writeback
// requests, and any other memory requests outside the designated
// address range of Near_Mem.  There are two Client interfaces to
// accommodate IMem and DMem requests concurrently.

// This implementation of Near_Mem contains an ICache and a DCache
//        Fabric-side Server interface is not used (no back door to caches).

package Near_Mem_Caches;

// ================================================================
// BSV lib imports

import ConfigReg    :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;
import Connectable  :: *;

// ----------------
// BSV additional libs

import Cur_Cycle  :: *;
import GetPut_Aux :: *;
import Routable   :: *;
import AXI4       :: *;

// ================================================================
// Project imports

import ISA_Decls    :: *;
import Near_Mem_IFC :: *;
import MMU_Cache    :: *;
import Fabric_Defs  :: *;

`ifdef INCLUDE_DMEM_SLAVE
import MMU_Cache_Arbiter           :: *;
import AXI4_Lite_MMU_Cache_Adapter :: *;
`endif

// System address map and pc_reset value
import SoC_Map :: *;

// ================================================================
// Exports

export mkNear_Mem;

// ================================================================
// The module

// Module state
typedef enum {STATE_RESET, STATE_RESETTING, STATE_READY } State
deriving (Bits, Eq, FShow);

(* synthesize *)
module mkNear_Mem (Near_Mem_IFC);

   Reg #(Bit #(4)) cfg_verbosity <- mkConfigReg (0);
   Reg #(State)    rg_state      <- mkReg (STATE_READY);

   // ----------------
   // System address map and pc reset value
   SoC_Map_IFC  soc_map  <- mkSoC_Map;

   // Reset response queue
   FIFOF #(Token) f_reset_rsps <- mkFIFOF;

   MMU_ICache_IFC  icache <- mkMMU_ICache;
   MMU_DCache_IFC  dcache <- mkMMU_DCache;
`ifdef INCLUDE_DMEM_SLAVE
   MMU_Cache_Arbiter_IFC #(2, Wd_MId_2x3) dcache_arbiter <- mkMMU_Cache_Arbiter (dcache);
   dcache = dcache_arbiter.v_from_masters [0];

   AXI4_Lite_MMU_Cache_Adapter_IFC dmem_slave_adapter <- mkAXI4_Lite_MMU_Cache_Adapter(dcache_arbiter.v_from_masters [1]);
`endif

   // ----------------------------------------------------------------
   // BEHAVIOR

   // ----------------
   // Reset
   // This reset state machine operates on external soft-reset request.

   rule rl_reset (rg_state == STATE_RESET);
      icache.server_reset.request.put (?);
      dcache.server_reset.request.put (?);
      rg_state <= STATE_RESETTING;

      if (cfg_verbosity > 1)
	 $display ("%0d: Near_Mem.rl_reset", cur_cycle);
   endrule

   rule rl_reset_complete (rg_state == STATE_RESETTING);
      let _dummy1 <- icache.server_reset.response.get;
      let _dummy2 <- dcache.server_reset.response.get;

      f_reset_rsps.enq (?);
      rg_state <= STATE_READY;

      if (cfg_verbosity > 1)
	 $display ("%0d: Near_Mem.rl_reset_complete", cur_cycle);
   endrule

   // ----------------------------------------------------------------
   // INTERFACE

   // Reset
   interface Server server_reset;
      interface Put request;
	 method Action put (Token t) if (rg_state == STATE_READY);
	    rg_state <= STATE_RESET;
	 endmethod
      endinterface

      interface Get response;
	 method ActionValue #(Token) get ();
	    let rsp <- pop (f_reset_rsps);
	    return rsp;
	 endmethod
      endinterface
   endinterface

   // ----------------
   // IMem

   // CPU side
   interface IMem_IFC imem;
      // CPU side: IMem request
      method Action  req (Bit #(3) width_code,
			  WordXL addr,
			  // The following  args for VM
			  Priv_Mode  priv,
			  Bit #(1)   sstatus_SUM,
			  Bit #(1)   mstatus_MXR,
			  WordXL     satp
`ifdef RVFI_DII
            , Dii_Id seq_req
`endif
                             );    // { VM_Mode, ASID, PPN_for_page_table }
	 Bit #(5)  amo_funct5  = ?;
	 Bit #(128) store_value = ?;
	 icache.req (CACHE_LD, width_code, True,
`ifdef ISA_A
		     amo_funct5,
`endif
         addr, tuple2(False, store_value),
                                priv, sstatus_SUM, mstatus_MXR, satp);
      endmethod

`ifdef ISA_CHERI
      method Action commit;
          icache.commit;
      endmethod
`endif

      // CPU side: IMem response
      method Bool     valid          = icache.valid;
      method Bool     is_i32_not_i16 = True;
      method WordXL   pc             = icache.addr;
`ifdef RVFI_DII
      method Tuple2#(Instr,Dii_Id)    instr    = tuple2(truncate(tpl_2(icache.word128)), 0);
`else
      method Instr    instr          = truncate(tpl_2(icache.word128));
`endif
      method Bool     exc            = icache.exc;
      method Exc_Code exc_code       = icache.exc_code;
      method WordXL   tval           = icache.addr;
   endinterface

   // Fabric side
   interface imem_master = icache.mem_master;

   // ----------------
   // DMem

   // CPU side
   interface DMem_IFC dmem;
      // CPU side: DMem request
      method Action  req (CacheOp op,
			  Bit #(3) width_code,
              Bool is_unsigned,
`ifdef ISA_A
			  Bit #(5) amo_funct5,
`endif
			  WordXL addr,
			  Tuple2#(Bool, Bit #(128)) store_value,
			  // The following  args for VM
			  Priv_Mode  priv,
			  Bit #(1)   sstatus_SUM,
			  Bit #(1)   mstatus_MXR,
			  WordXL     satp);    // { VM_Mode, ASID, PPN_for_page_table }
	 dcache.req (op, width_code, is_unsigned,
`ifdef ISA_A
		     amo_funct5,
`endif
		     addr, store_value,
                                priv, sstatus_SUM, mstatus_MXR, satp);
      endmethod

`ifdef ISA_CHERI
      method Action commit;
          dcache.commit;
      endmethod
`endif

      // CPU side: DMem response
      method Bool       valid      = dcache.valid;
      method Tuple2#(Bool, Bit #(128))  word128     = dcache.word128;
`ifdef ISA_A
      method Bit #(128)  st_amo_val = tpl_2(dcache.st_amo_val);
`endif
      method Bool       exc        = dcache.exc;
      method Exc_Code   exc_code   = dcache.exc_code;
   endinterface

   // Fabric side
   interface dmem_master = dcache.mem_master;

`ifdef INCLUDE_DMEM_SLAVE
   interface dmem_slave = dmem_slave_adapter.from_master;
`endif

   // ----------------
   // FENCE.I: flush both ICache and DCache

   interface Server server_fence_i;
      interface Put request;
	 method Action put (Token t) if (rg_state != STATE_RESET);
	    icache.server_flush.request.put (?);
	    dcache.server_flush.request.put (?);
	 endmethod
      endinterface
      interface Get response;
	 method ActionValue #(Token) get;
	    let ti <- icache.server_flush.response.get;
	    let td <- dcache.server_flush.response.get;
	    return ?;
	 endmethod
      endinterface
   endinterface

   // ----------------
   // FENCE: flush DCache

   interface Server server_fence;
      interface Put request;
	 method Action put (Fence_Ordering t);
	    dcache.server_flush.request.put (?);
	 endmethod
      endinterface
      interface Get response;
	 method ActionValue #(Token) get;
	    let td <- dcache.server_flush.response.get;
	    return ?;
	 endmethod
      endinterface
   endinterface

   // ----------------
   // SFENCE_VMA: flush TLBs

   method Action sfence_vma;
      icache.tlb_flush;
      dcache.tlb_flush;
   endmethod
endmodule

// ================================================================

endpackage: Near_Mem_Caches
