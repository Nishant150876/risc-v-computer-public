/* Real codec/worker loop with a deterministic reply tape, not a CPU model. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "device/link_device.h"

typedef struct {
    app_state_t app;
    uint8_t wire[DBL_MAX_WIRE];
    size_t length;
    unsigned sends,messages;
    bool pending,refuse;
} context_t;
static context_t ctx;
static link_device_t dev;
static uint32_t now;
static unsigned checks;
#define CHECK(x) do { assert(x); checks++; } while(0)
static void put32(uint8_t *p,uint32_t value) { for(unsigned i=0;i<4;i++) p[i]=(uint8_t)(value>>(i*8)); }
static void put64(uint8_t *p,uint64_t value) { for(unsigned i=0;i<8;i++) p[i]=(uint8_t)(value>>(i*8)); }

static bool send_wire(void *opaque,const uint8_t *wire,size_t length)
{
    context_t *c=opaque;
    if(c->refuse || c->pending) return false;
    CHECK(length<=sizeof c->wire); memcpy(c->wire,wire,length); c->length=length; c->pending=true; c->sends++;
    return true;
}
static void emit(void *opaque,const dev_msg_t *message)
{
    context_t *c=opaque; app_state_apply(&c->app,message); c->messages++;
}
static void init(void)
{
    memset(&ctx,0,sizeof ctx); app_state_init(&ctx.app); now=0;
    link_device_init(&dev,UINT64_C(0x1122334455667788),now,send_wire,emit,&ctx);
}
static dbl_frame_t take(uint16_t opcode)
{
    now+=10; link_device_tick(&dev,now);
    CHECK(ctx.pending); dbl_frame_t frame;
    CHECK(dbl_wire_decode(ctx.wire,ctx.length-1,&frame)==DBL_ERR_OK);
    CHECK(frame.opcode==opcode); ctx.pending=false; return frame;
}
static void reply(const dbl_frame_t *request,uint16_t status,const uint8_t *payload,uint16_t length)
{
    dbl_frame_t frame; uint8_t wire[DBL_MAX_WIRE];
    CHECK(dbl_frame_set(&frame,request->channel,DBL_KIND_RESPONSE,request->opcode,status,
        request->request_id,request->session_id,payload,length)==0);
    size_t n=dbl_wire_encode(&frame,wire); CHECK(n>0);
    for(size_t i=0;i<n;i+=7) {
        size_t chunk=n-i<7 ? n-i : 7; now++;
        link_device_feed(&dev,wire+i,chunk,now);
    }
}
static void handshake(uint32_t capabilities)
{
    uint8_t payload[36]={1,0,36,0};
    put32(payload+4,0x44330001); put32(payload+8,1); put32(payload+12,25000000);
    payload[16]=0; payload[17]=1; payload[18]=192; put32(payload+20,capabilities);
    payload[24]=2; payload[28]=DBL_CPU_HALTED;
    dbl_frame_t f=take(DBL_OP_HELLO); CHECK(f.request_id==0 && f.session_id==0);
    reply(&f,DBL_ST_OK,payload,sizeof payload);
    f=take(DBL_OP_HELLO); CHECK(f.request_id==1 && f.session_id==dev.session);
    payload[30]=DBL_SESSION_YOURS; payload[32]=0xd0; payload[33]=7;
    reply(&f,DBL_ST_OK,payload,sizeof payload);
    CHECK(dev.connected && ctx.app.hw.have_id && ctx.app.hw.link==LINK_CONNECTED);
    CHECK(ctx.app.hw.id.capabilities==capabilities && ctx.app.hw.id.clock_hz==25000000);
}
static void status_reply(uint8_t state)
{
    uint8_t p[36]={0}; p[0]=state; p[3]=7;
    put32(p+4,4); put32(p+8,8); put32(p+12,1); put32(p+32,9);
    dbl_frame_t f=take(DBL_OP_STATUS); reply(&f,DBL_ST_OK,p,sizeof p);
}
static void captures(bool bad_x0)
{
    uint8_t p[136]={0};
    p[0]=1; p[2]=64; p[3]=6; put32(p+4,7); put64(p+8,UINT64_C(1)<<40); put64(p+16,UINT64_C(1)<<39);
    put64(p+24,5); put64(p+32,6); put64(p+40,7); put64(p+48,8); put32(p+56,2); p[60]=1;
    dbl_frame_t f=take(DBL_OP_COUNTERS_LATCH); reply(&f,DBL_ST_OK,p,64);
    memset(p,0,sizeof p); put32(p,12); p[5]=32;
    for(unsigned i=0;i<32;i++) put32(p+8+4*i,i*0x1234);
    if(bad_x0) put32(p+8,1);
    f=take(DBL_OP_REG_READ); CHECK(f.length==4 && f.payload[0]==0 && f.payload[1]==32);
    reply(&f,DBL_ST_OK,p,sizeof p);
}
int main(void)
{
    init(); handshake(DBL_CAP_BASE_STATUS); status_reply(DBL_CPU_RUNNING);
    CHECK(ctx.app.hw.snap.prov==PROV_LIVE && ctx.app.hw.snap.pc==8 && ctx.app.hw.snap.last_pc==4);
    CHECK(!ctx.app.hw.snap.regs_valid && ctx.app.hw.snap.counter_mask==0 && dev.phase==LD_WAIT);
    ui_cmd_t command={.type=CMD_CPU_STEP}; CHECK(!link_device_command(&dev,&command,now));
    command.type=CMD_SIM_TRANSFER; CHECK(!link_device_command(&dev,&command,now));
    CHECK(ctx.app.hw.console_len==0); /* no fabricated console */
    command.type=CMD_LINK_RECONNECT; uint64_t old_session=dev.session;
    CHECK(link_device_command(&dev,&command,now) && dev.session!=old_session);

    init(); handshake(DBL_CAP_BASE_STATUS|DBL_CAP_REG_ACCESS|DBL_CAP_PERF64|DBL_CAP_HALT_RESUME|DBL_CAP_STEP);
    status_reply(DBL_CPU_HALTED);
    command.type=CMD_CPU_STEP; CHECK(link_device_command(&dev,&command,now)); /* queued during read-only polling */
    captures(false);
    CHECK(dev.phase==LD_WAIT && ctx.app.hw.snap.prov==PROV_LIVE && ctx.app.hw.snap.regs_valid);
    CHECK(ctx.app.hw.snap.regs[4]==4*0x1234 && ctx.app.hw.snap.regs[0]==0);
    CHECK(ctx.app.hw.snap.ctr.cycles==(UINT64_C(1)<<40) && ctx.app.hw.snap.ctr.instret==(UINT64_C(1)<<39));
    CHECK(ctx.app.hw.snap.counter_mask==0x173 && (ctx.app.hw.snap.counter_mask & 0x8c)==0);
    CHECK(ctx.app.hw.snap.counter_generation==7 && ctx.app.hw.snap.regs_generation==12 && ctx.app.hw.snap.cpu_epoch==2);
    CHECK(ctx.app.hw.snap.regs_t_ms>ctx.app.hw.snap.counter_t_ms && ctx.app.hw.snap.counter_t_ms>ctx.app.hw.snap_t_ms);
    dbl_frame_t f=take(DBL_OP_STEP); CHECK(f.request_id>1 && f.session_id==dev.session);
    uint8_t saved[DBL_MAX_WIRE]; size_t saved_length=ctx.length; memcpy(saved,ctx.wire,ctx.length);
    command.type=CMD_LINK_RECONNECT; CHECK(!link_device_command(&dev,&command,now));
    for(unsigned i=0;i<DBL_MAX_RETRIES;i++) {
        now+=501; link_device_tick(&dev,now);
        CHECK(ctx.pending && ctx.length==saved_length && memcmp(ctx.wire,saved,saved_length)==0); ctx.pending=false;
    }
    now+=501; link_device_tick(&dev,now);
    CHECK(dev.phase==LD_ERROR && dev.uncertain && ctx.app.hw.link==LINK_ERROR);
    unsigned sends=ctx.sends;
    for(unsigned i=0;i<100;i++) { now+=100; link_device_tick(&dev,now); }
    CHECK(ctx.sends==sends && !link_device_command(&dev,&command,now));
    CHECK(ctx.app.hw.snap.regs_valid && app_state_is_stale(&ctx.app,now));

    init(); handshake(DBL_CAP_BASE_STATUS|DBL_CAP_REG_ACCESS|DBL_CAP_PERF64);
    status_reply(DBL_CPU_HALTED); captures(true);
    CHECK(dev.phase==LD_ERROR && ctx.app.hw.snap.prov==PROV_NONE); /* corrupt capture never becomes LIVE */

    init(); handshake(DBL_CAP_BASE_STATUS|DBL_CAP_REG_ACCESS|DBL_CAP_PERF64);
    status_reply(DBL_CPU_HALTED); captures(false);
    CHECK(ctx.app.hw.snap.regs_valid);
    now+=250; status_reply(DBL_CPU_RUNNING);
    uint8_t counters[64]={1,0,64,6}; put32(counters+4,8); put32(counters+56,3);
    f=take(DBL_OP_COUNTERS_LATCH); reply(&f,DBL_ST_OK,counters,sizeof counters);
    CHECK(!ctx.app.hw.snap.regs_valid && ctx.app.hw.snap.cpu_epoch==3 && dev.phase==LD_WAIT);

    init(); handshake(DBL_CAP_BASE_STATUS|DBL_CAP_HALT_RESUME|DBL_CAP_STEP);
    status_reply(DBL_CPU_HALTED);
    command.type=CMD_CPU_STEP; CHECK(link_device_command(&dev,&command,now));
    f=take(DBL_OP_STEP); reply(&f,DBL_ST_OUTCOME_UNKNOWN,NULL,0);
    CHECK(dev.phase==LD_ERROR && dev.uncertain);
    command.type=CMD_LINK_RECONNECT; CHECK(!link_device_command(&dev,&command,now));

    init(); ctx.refuse=true; link_device_tick(&dev,++now);
    CHECK(dev.phase==LD_ERROR && ctx.sends==0 && ctx.app.hw.snap.prov==PROV_NONE);
    printf("PASS: %u real-link worker checks: discovery/capabilities, actual decoded status/registers/64-bit counters, unavailable fields, separate capture ages, queued controls, identical retries, uncertain-outcome lock and no MOCK fallback\n",checks);
    return 0;
}
