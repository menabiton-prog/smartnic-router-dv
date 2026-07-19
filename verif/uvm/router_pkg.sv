// ---------------------------------------------------------------------------
// router_pkg.sv
// UVM verification environment for packet_router.
//
//   * router_packet    : a packet transaction (header + payload flits)
//   * packet_sequence  : constrained-random stream of packets
//   * in_driver        : drives one input AXI4-Stream port
//   * in_monitor       : rebuilds packets seen entering an input port
//   * out_monitor      : rebuilds packets leaving an output port
//   * router_scoreboard: checks every packet reaches the port in its header,
//                        intact, with nothing lost or duplicated (+ coverage)
//   * router_env / router_test : wire it all up
//
// The scoreboard's notion of "correct" is the same as model/router_model.py.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

package router_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int N      = 4;
    localparam int DATA_W = 32;

    `uvm_analysis_imp_decl(_in)
    `uvm_analysis_imp_decl(_out)

    // -------------------------------------------------------------- packet ---
    class router_packet extends uvm_sequence_item;
        rand bit [1:0]        dest;
        rand int unsigned     length;              // 1..8 flits (header incl.)
        rand bit [DATA_W-1:0] payload [];          // length-1 payload words
        int unsigned          pid;                 // set by the driver
        int unsigned          src;                 // input port (driver/monitor)
        int unsigned          out_port;            // output port (out monitor)
        bit  [DATA_W-1:0]     words [$];           // full flit list incl. header

        `uvm_object_utils_begin(router_packet)
            `uvm_field_int(dest, UVM_ALL_ON)
            `uvm_field_int(length, UVM_ALL_ON)
            `uvm_field_int(pid, UVM_ALL_ON)
        `uvm_object_utils_end

        constraint c_len { length inside {[1:8]}; }
        constraint c_pl  { payload.size() == length - 1; }

        function new(string name = "router_packet"); super.new(name); endfunction

        // header layout matches model/router_model.py
        function bit [DATA_W-1:0] header();
            return (dest & 2'h3) | ((length & 14'h3FFF) << 2) | ((pid & 16'hFFFF) << 16);
        endfunction

        function void build_words();
            words.delete();
            words.push_back(header());
            foreach (payload[i]) words.push_back(payload[i]);
        endfunction
    endclass

    // ------------------------------------------------------------ sequence ---
    class packet_sequence extends uvm_sequence #(router_packet);
        `uvm_object_utils(packet_sequence)
        rand int unsigned n_packets = 40;
        function new(string name = "packet_sequence"); super.new(name); endfunction
        task body();
            repeat (n_packets) begin
                router_packet p = router_packet::type_id::create("p");
                start_item(p);
                if (!p.randomize()) `uvm_error("SEQ", "randomize failed")
                finish_item(p);
            end
        endtask
    endclass

    // -------------------------------------------------------------- driver ---
    class in_driver extends uvm_driver #(router_packet);
        `uvm_component_utils(in_driver)
        virtual router_if #(N, DATA_W) vif;
        int unsigned port;
        int unsigned pid_ctr = 0;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual router_if #(N, DATA_W))::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "no vif")
            void'(uvm_config_db#(int unsigned)::get(this, "", "port", port));
        endfunction

        task run_phase(uvm_phase phase);
            vif.s_tvalid[port] <= 1'b0;
            @(posedge vif.aresetn);
            forever begin
                router_packet p;
                seq_item_port.get_next_item(p);
                p.src = port;
                p.pid = (port << 12) | (pid_ctr++);   // unique across ports
                p.build_words();
                drive(p);
                seq_item_port.item_done();
            end
        endtask

        task drive(router_packet p);
            foreach (p.words[i]) begin
                @(posedge vif.aclk);
                vif.s_tdata[port]  <= p.words[i];
                vif.s_tvalid[port] <= 1'b1;
                vif.s_tlast[port]  <= (i == p.words.size() - 1);
                // hold until the beat is accepted
                do @(posedge vif.aclk); while (vif.s_tready[port] !== 1'b1);
                vif.s_tvalid[port] <= 1'b0;
                vif.s_tlast[port]  <= 1'b0;
            end
        endtask
    endclass

    // ------------------------------------------------------------- monitors --
    class in_monitor extends uvm_monitor;
        `uvm_component_utils(in_monitor)
        virtual router_if #(N, DATA_W) vif;
        int unsigned port;
        uvm_analysis_port #(router_packet) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual router_if #(N, DATA_W))::get(this, "", "vif", vif))
                `uvm_fatal("MON", "no vif")
            void'(uvm_config_db#(int unsigned)::get(this, "", "port", port));
        endfunction
        task run_phase(uvm_phase phase);
            bit [DATA_W-1:0] w [$];
            forever begin
                @(posedge vif.aclk);
                if (vif.s_tvalid[port] === 1'b1 && vif.s_tready[port] === 1'b1) begin
                    w.push_back(vif.s_tdata[port]);
                    if (vif.s_tlast[port] === 1'b1) begin
                        router_packet p = router_packet::type_id::create("in");
                        p.words = w; p.src = port;
                        p.dest  = w[0][1:0];
                        p.pid   = (w[0] >> 16) & 16'hFFFF;
                        ap.write(p);
                        w.delete();
                    end
                end
            end
        endtask
    endclass

    class out_monitor extends uvm_monitor;
        `uvm_component_utils(out_monitor)
        virtual router_if #(N, DATA_W) vif;
        int unsigned port;
        uvm_analysis_port #(router_packet) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual router_if #(N, DATA_W))::get(this, "", "vif", vif))
                `uvm_fatal("MON", "no vif")
            void'(uvm_config_db#(int unsigned)::get(this, "", "port", port));
        endfunction
        task run_phase(uvm_phase phase);
            bit [DATA_W-1:0] w [$];
            forever begin
                @(posedge vif.aclk);
                if (vif.m_tvalid[port] === 1'b1 && vif.m_tready[port] === 1'b1) begin
                    w.push_back(vif.m_tdata[port]);
                    if (vif.m_tlast[port] === 1'b1) begin
                        router_packet p = router_packet::type_id::create("out");
                        p.words    = w; p.out_port = port;
                        p.dest     = w[0][1:0];
                        p.pid      = (w[0] >> 16) & 16'hFFFF;
                        ap.write(p);
                        w.delete();
                    end
                end
            end
        endtask
    endclass

    // ---------------------------------------------------------- scoreboard ---
    class router_scoreboard extends uvm_component;
        `uvm_component_utils(router_scoreboard)

        uvm_analysis_imp_in  #(router_packet, router_scoreboard) in_ap;
        uvm_analysis_imp_out #(router_packet, router_scoreboard) out_ap;

        router_packet expected [int unsigned];   // by pid
        int unsigned  n_in, n_out, n_ok, n_bad;

        // functional coverage
        bit [1:0]     cg_dest;
        int unsigned  cg_len;
        int unsigned  cg_src;
        covergroup cg;
            option.per_instance = 1;
            cp_dest : coverpoint cg_dest;
            cp_len  : coverpoint cg_len  { bins l[] = {[1:8]}; }
            cp_src  : coverpoint cg_src  { bins s[] = {[0:N-1]}; }
            x_sd    : cross cp_src, cp_dest;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            in_ap = new("in_ap", this);
            out_ap = new("out_ap", this);
            cg = new();
        endfunction

        function void write_in(router_packet p);
            expected[p.pid] = p;
            n_in++;
            cg_dest = p.dest; cg_len = p.words.size(); cg_src = p.src; cg.sample();
        endfunction

        function void write_out(router_packet p);
            n_out++;
            if (!expected.exists(p.pid)) begin
                `uvm_error("SCB", $sformatf("unknown packet pid=%0d at output %0d",
                                            p.pid, p.out_port))
                n_bad++; return;
            end
            router_packet e = expected[p.pid];
            if (p.out_port != e.dest) begin
                `uvm_error("SCB", $sformatf("pid=%0d routed to %0d, expected %0d",
                                            p.pid, p.out_port, e.dest))
                n_bad++;
            end else if (p.words != e.words) begin
                `uvm_error("SCB", $sformatf("pid=%0d payload mismatch", p.pid))
                n_bad++;
            end else begin
                n_ok++;
            end
            expected.delete(p.pid);
        endfunction

        function void check_phase(uvm_phase phase);
            if (expected.size() != 0)
                `uvm_error("SCB", $sformatf("%0d packets never reached an output",
                                            expected.size()))
            `uvm_info("SCB", $sformatf(
                "in=%0d out=%0d ok=%0d bad=%0d coverage=%.1f%%",
                n_in, n_out, n_ok, n_bad, cg.get_inst_coverage()), UVM_LOW)
            if (n_bad != 0 || expected.size() != 0)
                `uvm_error("SCB", "TEST FAILED")
            else
                `uvm_info("SCB", "TEST PASSED", UVM_LOW)
        endfunction
    endclass

    // ----------------------------------------------------------------- env ---
    class router_env extends uvm_env;
        `uvm_component_utils(router_env)
        in_driver         drv [N];
        uvm_sequencer #(router_packet) sqr [N];
        in_monitor        imon [N];
        out_monitor       omon [N];
        router_scoreboard scb;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            scb = router_scoreboard::type_id::create("scb", this);
            for (int p = 0; p < N; p++) begin
                sqr[p]  = uvm_sequencer#(router_packet)::type_id::create($sformatf("sqr%0d", p), this);
                drv[p]  = in_driver ::type_id::create($sformatf("drv%0d", p), this);
                imon[p] = in_monitor::type_id::create($sformatf("imon%0d", p), this);
                omon[p] = out_monitor::type_id::create($sformatf("omon%0d", p), this);
                uvm_config_db#(int unsigned)::set(this, $sformatf("drv%0d",  p), "port", p);
                uvm_config_db#(int unsigned)::set(this, $sformatf("imon%0d", p), "port", p);
                uvm_config_db#(int unsigned)::set(this, $sformatf("omon%0d", p), "port", p);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            for (int p = 0; p < N; p++) begin
                drv[p].seq_item_port.connect(sqr[p].seq_item_export);
                imon[p].ap.connect(scb.in_ap);
                omon[p].ap.connect(scb.out_ap);
            end
        endfunction
    endclass

    // ---------------------------------------------------------------- test ---
    class router_test extends uvm_test;
        `uvm_component_utils(router_test)
        router_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            env = router_env::type_id::create("env", this);
        endfunction
        task run_phase(uvm_phase phase);
            packet_sequence seq [N];
            phase.raise_objection(this);
            for (int p = 0; p < N; p++) begin
                seq[p] = packet_sequence::type_id::create($sformatf("seq%0d", p));
                void'(seq[p].randomize() with { n_packets == 40; });
            end
            fork
                begin automatic int i0 = 0; seq[0].start(env.sqr[0]); end
                begin automatic int i1 = 1; seq[1].start(env.sqr[1]); end
                begin automatic int i2 = 2; seq[2].start(env.sqr[2]); end
                begin automatic int i3 = 3; seq[3].start(env.sqr[3]); end
            join
            // let the pipeline drain
            repeat (500) @(posedge env.drv[0].vif.aclk);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
