/* Real packets only. No timer-generated CPU state, fake counters or MOCK fallback. */
#include "link_device.h"
#include <stdio.h>
#include <string.h>

static uint32_t read32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}

static void link_message(link_device_t *d, link_state_t state, const char *why, uint32_t now)
{
    dev_msg_t m={.type=MSG_LINK,.t_ms=now};
    m.u.link.state=state;
    snprintf(m.u.link.reason,sizeof m.u.link.reason,"%s",why);
    d->emit(d->ctx,&m);
}

static void fail(link_device_t *d, const char *why, uint32_t now)
{
    d->phase=LD_ERROR; d->connected=false;
    link_message(d,LINK_ERROR,why,now);
}

static bool capable(const link_device_t *d, uint32_t capability)
{
    return (d->descriptor.capabilities & capability)!=0;
}

static void send_wire(link_device_t *d, uint32_t now)
{
    if(!d->send(d->ctx,d->client.wire,d->client.wire_len)) {
        if(d->phase==LD_COMMAND) d->uncertain=true;
        fail(d,"TX queue refused; reconcile",now);
    }
}

void link_device_init(link_device_t *d, uint64_t session, uint32_t now,
                      link_send_fn send, link_emit_fn emit, void *ctx)
{
    memset(d,0,sizeof *d);
    dbl_client_init(&d->client); dbl_rx_init(&d->rx,DBL_INTERBYTE_TIMEOUT_MS);
    d->session=session ? session : 1; d->send=send; d->emit=emit; d->ctx=ctx;
    d->phase=LD_DISCOVER; d->due_ms=now;
    link_message(d,LINK_CONNECTING,"Discovering packet endpoint",now);
}

static cpu_state_t cpu_state(uint8_t state)
{
    switch(state) {
    case DBL_CPU_RESET_HELD: return CPU_RESET_HELD;
    case DBL_CPU_HALTED: return CPU_HALTED;
    case DBL_CPU_RUNNING: return CPU_RUNNING;
    case DBL_CPU_HALT_REQUESTED: case DBL_CPU_STEPPING: return CPU_STEPPING;
    case DBL_CPU_BREAKPOINT: return CPU_BREAKPOINT;
    case DBL_CPU_TERMINATED: return CPU_TERMINATED;
    case DBL_CPU_ERROR: return CPU_ERROR;
    default: return CPU_UNKNOWN;
    }
}

static void publish(link_device_t *d)
{
    dev_msg_t m={.type=MSG_SNAPSHOT,.t_ms=d->status_ms};
    m.u.snap=d->snapshot; d->emit(d->ctx,&m);
    d->phase=LD_WAIT; d->due_ms=d->status_ms+200;
}

static void after_counters(link_device_t *d)
{
    cpu_state_t state=d->snapshot.cpu;
    if(capable(d,DBL_CAP_REG_ACCESS) && (state==CPU_HALTED || state==CPU_BREAKPOINT || state==CPU_TERMINATED || state==CPU_ERROR))
        d->phase=LD_REGISTERS;
    else publish(d);
}

static void on_match(link_device_t *d, const dbl_frame_t *f, uint32_t now)
{
    if(f->status==DBL_ST_OUTCOME_UNKNOWN && d->phase==LD_COMMAND) {
        d->uncertain=true;
        fail(d,"OUTCOME UNKNOWN; reconcile first",now); return;
    }
    if(f->status==DBL_ST_BAD_SESSION) { fail(d,"Session lost; reconnect/reconcile",now); return; }
    if(f->status!=DBL_ST_OK && f->status!=DBL_ST_ACCEPTED) {
        if(d->phase==LD_CLAIM && f->status==DBL_ST_BUSY) {
            dbl_client_set_session(&d->client,0); d->phase=LD_DISCOVER; d->due_ms=now+500;
            link_message(d,LINK_CONNECTING,"Another client owns the lease",now); return;
        }
        if(d->phase==LD_REGISTERS && f->status==DBL_ST_BAD_STATE) { d->snapshot.regs_valid=false; publish(d); return; }
        fail(d,"Device rejected typed request",now); return;
    }
    if(d->phase==LD_DISCOVER || d->phase==LD_CLAIM) {
        dbl_hello_response_t hello;
        if(dbl_unpack_hello_response(f->payload,f->length,&hello)!=0 || hello.protocol_version!=DBL_PROTOCOL_VERSION ||
           hello.descriptor_bytes!=DBL_HELLO_RESPONSE_BYTES || hello.max_payload>DBL_MAX_PAYLOAD ||
           !(hello.capabilities & DBL_CAP_BASE_STATUS)) { fail(d,"Incompatible HELLO descriptor",now); return; }
        d->descriptor=hello;
        if(d->phase==LD_DISCOVER) { dbl_client_set_session(&d->client,d->session); d->phase=LD_CLAIM; }
        else {
            dev_msg_t m={.type=MSG_IDENTITY,.t_ms=now};
            snprintf(m.u.id.board,sizeof m.u.id.board,"FPGA endpoint");
            snprintf(m.u.id.core,sizeof m.u.id.core,"%s",hello.isa_flags & DBL_ISA_RV32I ? "RV32I (reported)" : "ISA unspecified");
            snprintf(m.u.id.bitstream,sizeof m.u.id.bitstream,"build %08lx",(unsigned long)hello.build_id);
            m.u.id.clock_hz=hello.clock_hz; m.u.id.protocol_version=hello.protocol_version; m.u.id.capabilities=hello.capabilities;
            m.u.id.can_halt=capable(d,DBL_CAP_HALT_RESUME); m.u.id.can_step=capable(d,DBL_CAP_STEP);
            d->emit(d->ctx,&m); d->connected=true; d->phase=LD_STATUS;
            link_message(d,LINK_CONNECTED,"Real packet link; capabilities checked",now);
        }
    } else if(d->phase==LD_STATUS) {
        dbl_status_response_t status;
        if(dbl_unpack_status_response(f->payload,f->length,&status)!=0) { fail(d,"Invalid STATUS length",now); return; }
        d->snapshot.prov=PROV_LIVE; d->snapshot.cpu=cpu_state(status.cpu_state);
        d->snapshot.pc=status.next_pc; d->snapshot.last_pc=status.last_retired_pc;
        d->snapshot.pc_valid=status.valid & 3u; d->snapshot.generation=status.snapshot_generation; d->status_ms=now;
        d->snapshot.image_valid=(status.valid & DBL_VALID_IMAGE)!=0; d->snapshot.operation_state=status.operation_state;
        dev_msg_t operation={.type=MSG_OP,.t_ms=now};
        operation.u.op.state=status.operation_state==DBL_OPST_IDLE ? OP_IDLE :
            status.operation_state==DBL_OPST_DONE ? OP_DONE : status.operation_state==DBL_OPST_FAILED ? OP_FAILED : OP_TRANSFER;
        snprintf(operation.u.op.detail,sizeof operation.u.op.detail,"FPGA operation state %u",status.operation_state);
        d->emit(d->ctx,&operation);
        if(d->snapshot.cpu==CPU_RESET_HELD) d->snapshot.regs_valid=false;
        if(capable(d,DBL_CAP_PERF64)) d->phase=LD_COUNTERS; else after_counters(d);
    } else if(d->phase==LD_COUNTERS) {
        dbl_counters_response_t counters;
        if(dbl_unpack_counters_response(f->payload,f->length,&counters)!=0 || counters.definition_version!=1 ||
           counters.width!=64 || counters.count!=6) { fail(d,"Unknown counter definition",now); return; }
        d->snapshot.ctr.cycles=counters.cycles; d->snapshot.ctr.instret=counters.instructions;
        d->snapshot.ctr.loads=counters.loads; d->snapshot.ctr.stores=counters.stores;
        d->snapshot.ctr.branches=counters.branches; d->snapshot.ctr.jumps=counters.jumps;
        d->snapshot.counter_mask=0x173; /* stalls/flushes/branches-taken were not supplied */
        d->snapshot.counter_generation=counters.generation; d->snapshot.counter_t_ms=now;
        if(d->snapshot.cpu_epoch!=counters.cpu_epoch) d->snapshot.regs_valid=false;
        d->snapshot.cpu_epoch=counters.cpu_epoch; after_counters(d);
    } else if(d->phase==LD_REGISTERS) {
        dbl_reg_read_response_t h;
        if(f->length!=136 || dbl_unpack_reg_read_response(f->payload,8,&h)!=0 || h.start!=0 || h.count!=32) {
            fail(d,"Invalid register capture",now); return;
        }
        for(unsigned i=0;i<32;i++) d->snapshot.regs[i]=read32(f->payload+8+i*4);
        if(d->snapshot.regs[0]!=0) { fail(d,"FPGA reported nonzero x0",now); return; }
        d->snapshot.regs_valid=true; d->snapshot.regs_generation=h.generation; d->snapshot.regs_t_ms=now; publish(d);
    } else if(d->phase==LD_COMMAND) {
        /* A control reply is not an atomic register/counter snapshot. Re-poll. */
        d->pending_command=0; d->phase=LD_STATUS;
    }
}

void link_device_feed(link_device_t *d, const uint8_t *bytes, size_t length, uint32_t now)
{
    for(size_t i=0;i<length;i++) {
        dbl_frame_t frame; int error;
        int event=dbl_rx_byte(&d->rx,bytes[i],now,&frame,&error);
        if(event==DBL_RX_ERROR) d->rejected++;
        else if(event==DBL_RX_FRAME) {
            d->received++;
            if(dbl_client_on_frame(&d->client,&frame)==DBL_CLIENT_MATCH) on_match(d,&frame,now);
        }
    }
}

void link_device_tick(link_device_t *d, uint32_t now)
{
    int error;
    if(dbl_rx_poll(&d->rx,now,&error)==DBL_RX_ERROR) d->rejected++;
    if(d->phase==LD_ERROR) return;
    dbl_client_result_t event=dbl_client_tick(&d->client,now);
    if(event==DBL_CLIENT_RESEND) { send_wire(d,now); return; }
    if(event==DBL_CLIENT_OUTCOME_UNKNOWN) {
        d->uncertain=d->phase==LD_COMMAND;
        fail(d,d->uncertain ? "OUTCOME UNKNOWN; reconcile first" : "No reply; reconnect required",now); return;
    }
    if(d->client.busy) return;
    if(d->pending_command!=0 && d->phase==LD_WAIT) { d->phase=LD_COMMAND; d->due_ms=now; }
    if((int32_t)(now-d->due_ms)<0) return;
    uint16_t opcode=DBL_OP_STATUS,len=0;
    uint8_t payload[4]={0};
    switch(d->phase) {
    case LD_DISCOVER:
        if(dbl_client_discover(&d->client,now)==DBL_CLIENT_WAITING) send_wire(d,now);
        return;
    case LD_CLAIM: opcode=DBL_OP_HELLO; break;
    case LD_WAIT: d->phase=LD_STATUS; break;
    case LD_STATUS: break;
    case LD_COUNTERS: opcode=DBL_OP_COUNTERS_LATCH; break;
    case LD_REGISTERS: opcode=DBL_OP_REG_READ; payload[1]=32; len=4; break;
    case LD_COMMAND: opcode=d->pending_command; break;
    default: return;
    }
    if(dbl_client_start(&d->client,DBL_CH_CONTROL,opcode,payload,len,now)==DBL_CLIENT_WAITING) send_wire(d,now);
    else fail(d,"Client session/queue unavailable",now);
}

bool link_device_command(link_device_t *d, const ui_cmd_t *command, uint32_t now)
{
    if(command->type==CMD_LINK_RECONNECT) {
        /* A lost mutation needs explicit state reconciliation, never automatic new-ID repetition. */
        if(d->uncertain || (d->client.busy && d->phase==LD_COMMAND)) { d->command_refused++; return false; }
        d->session+=UINT64_C(0x9e3779b97f4a7c15); if(d->session==0) d->session=1;
        dbl_client_set_session(&d->client,0); d->phase=LD_DISCOVER; d->due_ms=now;
        d->pending_command=0; d->connected=false;
        d->snapshot.regs_valid=false; d->snapshot.counter_mask=0;
        link_message(d,LINK_CONNECTING,"Re-discovering actual endpoint",now); return true;
    }
    uint16_t opcode;
    switch(command->type) {
    case CMD_CPU_HALT: opcode=DBL_OP_HALT; break;
    case CMD_CPU_RESUME: opcode=DBL_OP_RESUME; break;
    case CMD_CPU_STEP: opcode=DBL_OP_STEP; break;
    case CMD_CPU_RESET: opcode=DBL_OP_CPU_RESET; break;
    default: d->command_refused++; return false;
    }
    if(!d->connected || d->uncertain || d->pending_command!=0 ||
       !capable(d,opcode==DBL_OP_STEP ? DBL_CAP_STEP : DBL_CAP_HALT_RESUME)) { d->command_refused++; return false; }
    d->pending_command=opcode; return true;
}
