# Cocotb regression for packet_router (via the flattened wrapper).
#   make            # Icarus Verilog
#   make SIM=verilator
#   make clean

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

RTL := $(abspath ../../rtl)
VERILOG_SOURCES := \
    $(RTL)/router_fifo.sv \
    $(RTL)/rr_arbiter.sv \
    $(RTL)/packet_router.sv \
    $(RTL)/packet_router_flat.sv

TOPLEVEL := packet_router_flat
MODULE   := test_router

ifeq ($(SIM),icarus)
    COMPILE_ARGS += -g2012
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
