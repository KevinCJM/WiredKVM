"""Offline C glue + generated layout tests. No device/OS input access."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("profile_build",HERE/"build_profile.py")
profile=importlib.util.module_from_spec(spec);spec.loader.exec_module(profile)
STUB=r'''
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct {int unused;} usbd_handle_t;
typedef struct {uint8_t bmRequestType,bRequest;uint16_t wValue,wIndex,wLength;} usb_req_t;
typedef int usb_rst_e;
#define USB_RST_OK 0
#define USB_RST_FAILED -1
#define USB_SPEED_HIGH 2
extern int mock_speed;
static inline int usbd_get_speed(usbd_handle_t *h){(void)h;return mock_speed;}
'''

def public_apple_collection_model(report):
    """Small HID item parser for the two public Apple collection algorithms.

    Application/Physical collections contribute usage pairs; any collection
    can contribute ancestor usage. This is NOT a macOS driver emulator or
    proof that the current DriverKit driver dispatches pointer coordinates.
    """
    offset=0;page=0;report_id=0;size=0;count=0
    usages=[];usage_range=[];collections=[];pairs=set();inputs=[]
    while offset<len(report):
        prefix=report[offset];offset+=1
        if prefix==0xfe:raise ValueError("long items not used by this fixture")
        length=(0,1,2,4)[prefix&3]
        data=report[offset:offset+length]
        if len(data)!=length:raise ValueError("truncated HID short item")
        offset+=length;value=int.from_bytes(data,"little");kind=(prefix>>2)&3;tag=prefix>>4
        if kind==1:
            if tag==0:page=value
            elif tag==7:size=value
            elif tag==8:report_id=value
            elif tag==9:count=value
            elif tag in (10,11):raise ValueError("global stack not used by this fixture")
        elif kind==2:
            if tag==0:usages.append((value>>16,value&65535) if length==4 else (page,value))
            elif tag in (1,2):usage_range.append((tag,page,value))
        elif kind==0:
            if tag==10:
                if len(usages)!=1:raise ValueError("collection requires one usage")
                collection=(value,*usages[0]);collections.append(collection)
                if value in (0,1):pairs.add(usages[0])
            elif tag==12:
                if not collections:raise ValueError("unbalanced end collection")
                collections.pop()
            elif tag==8:
                inputs.append({"report_id":report_id,"usages":tuple(usages),
                    "range":tuple(usage_range),"size":size,"count":count,"flags":value,
                    "ancestors":tuple(collections)})
            usages=[];usage_range=[]
    if collections:raise ValueError("unclosed collection")
    return pairs,inputs

class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work=Path(tempfile.mkdtemp(prefix="mt2-profile-test-",dir=HERE))
        (cls.work/"usb_driver.h").write_text(STUB)
        cls.generated=cls.work/"generated-profile";profile.generate(cls.generated)
        print("MT2_PROFILE_TEST_ARTIFACTS",cls.work)

    def compile_run(self,name,body,extra=()):
        source=self.work/(name+".c");source.write_text(body)
        binary=self.work/name
        command=["clang","-std=c11","-Wall","-Wextra","-Werror","-I",str(self.work),"-I",str(HERE),"-I",str(profile.CORE/"include"),"-I",str(profile.ROOT/"firmware/ch32v407"),str(source),*[str(p) for p in extra],"-o",str(binary)]
        result=subprocess.run(command,text=True,capture_output=True);self.assertEqual(result.returncode,0,result.stderr)
        result=subprocess.run([str(binary)],text=True,capture_output=True);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        return result.stdout

    def test_configuration_retains_existing_layout_and_adds_only_interface6_ep7(self):
        body=r'''
#include <stdio.h>
#include "descriptors.h"
int mock_speed=2;static unsigned port;
unsigned wk407_port(usbd_handle_t *h){(void)h;return port;}
int main(void){for(port=0;port<2;port++)for(unsigned type=1;type<=2;type++){
usb_req_t r={.wValue=(uint16_t)(type<<8),.wLength=512};void *b;size_t n;
if(wk407_descriptor(NULL,&r,&b,&n))return 1;
printf("%u %u ",port,type);for(size_t i=0;i<n;i++)printf("%02x",((uint8_t *)b)[i]);puts("");}return 0;}
'''
        out=self.compile_run("layout",body,[self.generated/"generated/descriptors.c"])
        values={(int(p),int(t)):bytes.fromhex(h) for p,t,h in (line.split() for line in out.splitlines())}
        self.assertEqual(values[(0,1)][8:12],bytes.fromhex("861a7040"))
        self.assertEqual(values[(1,1)][8:12],bytes.fromhex("ac056502"))
        config=values[(1,2)];self.assertEqual(len(config),205);self.assertEqual(config[2:5],bytes([205,0,7]))
        blocks=[];i=0
        while i<len(config):
            n=config[i];self.assertGreaterEqual(n,2);blocks.append(config[i:i+n]);i+=n
        self.assertEqual(i,len(config))
        self.assertEqual([x[2] for x in blocks if x[1]==4],list(range(7)))
        self.assertEqual([x[2] for x in blocks if x[1]==5], [0x81,0x82,0x83,3,0x84,5,0x85,6,0x86,0x87])
        # Compare old descriptor byte-for-byte, excluding changed config length/count.
        old=self.compile_run("original-layout",body,[profile.ROOT/"firmware/ch32v407/descriptors.c"])
        original={(int(p),int(t)):bytes.fromhex(h) for p,t,h in (line.split() for line in old.splitlines())}
        self.assertEqual(values[(0,2)],original[(0,2)])
        self.assertEqual(config[5:180],original[(1,2)][5:])
        self.assertEqual(config[-7:],bytes([7,5,0x87,3,64,0,4]))

    def test_pointer_variant_changes_only_two_usage_bytes_and_target_version(self):
        variant=self.work/"pointer-profile";profile.generate(variant,pointer_collections=True)
        body=r'''
#include <stdio.h>
#include "descriptors.h"
int mock_speed=2;static unsigned port;
unsigned wk407_port(usbd_handle_t *h){(void)h;return port;}
static void print_bytes(const char *kind,unsigned id,void *b,size_t n){
printf("%s %u ",kind,id);for(size_t i=0;i<n;i++)printf("%02x",((uint8_t *)b)[i]);puts("");}
int main(void){void *b;size_t n;
for(port=0;port<2;port++){
usb_req_t r={.wValue=0x0100,.wLength=512};if(wk407_descriptor(NULL,&r,&b,&n))return 1;print_bytes("device",port,b,n);
for(mock_speed=1;mock_speed<=2;mock_speed++){r.wValue=0x0200;if(wk407_descriptor(NULL,&r,&b,&n))return 2;print_bytes("config",port*10+(unsigned)mock_speed,b,n);}}
port=1;for(unsigned i=0;i<3;i++){
usb_req_t r={.wValue=0x2200,.wIndex=(uint16_t)i,.wLength=512};if(wk407_hid_descriptor(NULL,&r,&b,&n))return 3;print_bytes("report",i,b,n);}
return 0;}
'''
        def collect(name,path):
            out=self.compile_run(name,body,[path/"generated/descriptors.c"])
            return {(kind,int(i)):bytes.fromhex(h) for kind,i,h in (line.split() for line in out.splitlines())}
        original=collect("base-reports",self.generated);changed=collect("pointer-reports",variant)
        self.assertEqual(original.keys(),changed.keys())
        for key in original:
            a,b=original[key],changed[key];self.assertEqual(len(a),len(b))
            diff=[i for i,(x,y) in enumerate(zip(a,b)) if x!=y]
            if key==("device",1):
                self.assertEqual(diff,[12]);self.assertEqual(a[12:14],b"\x68\x02");self.assertEqual(b[12:14],b"\x69\x02")
            elif key in (("report",0),("report",1)):
                self.assertEqual(len(diff),1);pos=diff[0]
                self.assertEqual(a[pos-3:pos+5],bytes([5,1,9,2,0xa1,1,0x85,key[1]+2]))
                self.assertEqual(b[pos],1)
            else:self.assertEqual(diff,[],key)
        self.assertEqual((self.generated/"generated/main.c").read_bytes(),(variant/"generated/main.c").read_bytes())

    def test_absolute_no_preferred_changes_only_xy_input_flag_and_version(self):
        pointer=self.work/"nopref-baseline";profile.generate(pointer,pointer_collections=True)
        variant=self.work/"nopref-variant";profile.generate(variant,pointer_collections=True,absolute_no_preferred=True)
        body=r'''
#include <stdio.h>
#include "descriptors.h"
int mock_speed=2;static unsigned port;
unsigned wk407_port(usbd_handle_t *h){(void)h;return port;}
static void emit(const char *k,unsigned id,void *b,size_t n){printf("%s %u ",k,id);for(size_t j=0;j<n;j++)printf("%02x",((uint8_t *)b)[j]);puts("");}
int main(void){void *b;size_t n;
for(port=0;port<2;port++)for(unsigned t=1;t<=2;t++){
usb_req_t r={.wValue=(uint16_t)(t<<8),.wLength=512};if(wk407_descriptor(NULL,&r,&b,&n))return 1;emit(t==1?"device":"config",port,b,n);}
port=1;for(unsigned i=0;i<3;i++){usb_req_t r={.wValue=0x2200,.wIndex=(uint16_t)i,.wLength=512};if(wk407_hid_descriptor(NULL,&r,&b,&n))return 2;emit("report",i,b,n);}return 0;}
'''
        def collect(name,path):
            out=self.compile_run(name,body,[path/"generated/descriptors.c"])
            return {(kind,int(i)):bytes.fromhex(h) for kind,i,h in (line.split() for line in out.splitlines())}
        original=collect("nopref-original",pointer);changed=collect("nopref-changed",variant)
        for key,a in original.items():
            b=changed[key];self.assertEqual(len(a),len(b));diff=[i for i,(x,y) in enumerate(zip(a,b)) if x!=y]
            if key==("device",1):
                self.assertEqual(diff,[12]);self.assertEqual(a[12:14],b"\x69\x02");self.assertEqual(b[12:14],b"\x6a\x02")
            elif key==("report",1):
                self.assertEqual(len(diff),1);pos=diff[0]
                self.assertEqual(a[pos-5:pos+3],bytes([0x75,16,0x95,2,0x81,2,9,0x38]));self.assertEqual(b[pos],0x22)
            else:self.assertEqual(diff,[],key)
        self.assertEqual((pointer/"generated/main.c").read_bytes(),(variant/"generated/main.c").read_bytes())
        invalid=self.work/"invalid-nopref"
        with self.assertRaisesRegex(ValueError,"requires pointer"):
            profile.generate(invalid,absolute_no_preferred=True)
        self.assertFalse(invalid.exists())

    def test_absolute_mouse_logical_preserves_wire_layout_and_models_collection_contract(self):
        pointer=self.work/"logical-baseline";profile.generate(pointer,pointer_collections=True)
        variant=self.work/"logical-variant";profile.generate(variant,pointer_collections=True,absolute_mouse_logical=True)
        body=r'''
#include <stdio.h>
#include "descriptors.h"
int mock_speed=2;static unsigned port;
unsigned wk407_port(usbd_handle_t *h){(void)h;return port;}
static void emit(const char *k,unsigned id,void *b,size_t n){printf("%s %u ",k,id);for(size_t j=0;j<n;j++)printf("%02x",((uint8_t *)b)[j]);puts("");}
int main(void){void *b;size_t n;
for(port=0;port<2;port++){
usb_req_t r={.wValue=0x0100,.wLength=512};if(wk407_descriptor(NULL,&r,&b,&n))return 1;emit("device",port,b,n);
for(mock_speed=1;mock_speed<=2;mock_speed++){r.wValue=0x0200;if(wk407_descriptor(NULL,&r,&b,&n))return 2;emit("config",port*10+(unsigned)mock_speed,b,n);}}
port=1;for(unsigned i=0;i<3;i++){usb_req_t r={.wValue=0x2200,.wIndex=(uint16_t)i,.wLength=512};if(wk407_hid_descriptor(NULL,&r,&b,&n))return 3;emit("report",i,b,n);}return 0;}
'''
        def collect(name,path):
            out=self.compile_run(name,body,[path/"generated/descriptors.c"])
            return {(kind,int(i)):bytes.fromhex(h) for kind,i,h in (line.split() for line in out.splitlines())}
        original=collect("logical-original",pointer);changed=collect("logical-changed",variant)
        self.assertEqual(original.keys(),changed.keys())
        for key,a in original.items():
            b=changed[key];self.assertEqual(len(a),len(b));diff=[i for i,(x,y) in enumerate(zip(a,b)) if x!=y]
            if key==("device",1):
                self.assertEqual(diff,[12]);self.assertEqual(a[12:14],b"\x69\x02");self.assertEqual(b[12:14],b"\x6b\x02")
            elif key==("report",1):
                self.assertEqual(diff,[9,11]);self.assertEqual(a[:12],bytes.fromhex("05010901a10185030901a100"))
                self.assertEqual(b[:12],bytes.fromhex("05010901a10185030902a102"))
            else:self.assertEqual(diff,[],key)
        old_pairs,old_inputs=public_apple_collection_model(original[("report",1)])
        pairs,inputs=public_apple_collection_model(changed[("report",1)])
        self.assertEqual(pairs,old_pairs);self.assertEqual(pairs,{(1,1)})
        # Fields and bit offsets are unchanged. Only ancestry differs.
        self.assertEqual([{k:v for k,v in i.items() if k!="ancestors"} for i in old_inputs],
                         [{k:v for k,v in i.items() if k!="ancestors"} for i in inputs])
        axes=[i for i in inputs if i["usages"]==((1,48),(1,49))]
        self.assertEqual(len(axes),1);axis=axes[0]
        self.assertEqual((axis["report_id"],axis["size"],axis["count"],axis["flags"]),(3,16,2,2))
        self.assertIn((2,1,2),axis["ancestors"])
        self.assertFalse(any(a[1:]==(1,2) for i in old_inputs for a in i["ancestors"]))
        physical=bytearray(changed[("report",1)]);physical[11]=0
        self.assertIn((1,2),public_apple_collection_model(physical)[0])
        self.assertEqual((pointer/"generated/main.c").read_bytes(),(variant/"generated/main.c").read_bytes())
        for name,args,message in [
            ("logical-without-pointer",dict(absolute_mouse_logical=True),"requires pointer"),
            ("logical-and-nopref",dict(pointer_collections=True,absolute_mouse_logical=True,absolute_no_preferred=True),"mutually exclusive")]:
            invalid=self.work/name
            with self.assertRaisesRegex(ValueError,message):profile.generate(invalid,**args)
            self.assertFalse(invalid.exists())

    def test_control_segmentation_overflow_feature_lengths_and_no_live_touch(self):
        body=r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "mt2_glue.h"
int mock_speed=2;static int enabled,frame;
void wkmt2_reset(void){enabled=frame=0;}
int wkmt2_enabled(void){return enabled;}
int wkmt2_report_descriptor(uint8_t *p,size_t n){if(n<110)return -1;memset(p,0,110);return 110;}
int wkmt2_feature_get(uint8_t id,uint8_t *p,size_t n){if(id!=0xdb||n<76)return -1;memset(p,0,76);p[0]=id;return 76;}
int wkmt2_feature_set(uint8_t id,const uint8_t *p,size_t n){if(id!=2||n!=1||p[0]>1)return -1;enabled=p[0];frame=enabled;return 0;}
int wkmt2_input(uint8_t *p,size_t n){if(!frame||n<12)return 0;memset(p,0,12);p[0]=2;frame=0;return 12;}
static uint8_t forwarded[4096];static size_t forwarded_size;
static void forward(void *ctx,const uint8_t *p,size_t n,uint32_t now){(void)ctx;(void)now;assert(forwarded_size+n<=sizeof(forwarded));memcpy(forwarded+forwarded_size,p,n);forwarded_size+=n;}
static void check(const char *stream,const char *expected){size_t n=strlen(stream);
for(size_t split=0;split<=n;split++){wkmt2_profile_host_reset();forwarded_size=0;
wkmt2_profile_control(NULL,forward,(const uint8_t *)stream,split,1);
wkmt2_profile_control(NULL,forward,(const uint8_t *)stream+split,n-split,1);
assert(forwarded_size==strlen(expected));assert(!memcmp(forwarded,expected,forwarded_size));
size_t length;const uint8_t *d=wkmt2_profile_diagnostic(&length);assert(d&&length>4&&!memcmp(d,"MT2,",4));
wkmt2_profile_diagnostic_done();assert(!wkmt2_profile_diagnostic(&length));}}
int main(void){
wkmt2_profile_reset();check("WK1,1,P,0,0,crc\nMT2?\nC1,abcdef,crc\n","WK1,1,P,0,0,crc\nC1,abcdef,crc\n");
check("MT2?\r\nWK1,1,R,0,0,crc\n","WK1,1,R,0,0,crc\n");
char stream[600],expected[600];memset(stream,'X',400);strcpy(stream+400,"\nMT2?\nWK1,R\n");memset(expected,'X',400);strcpy(expected+400,"\nWK1,R\n");check(stream,expected);
/* Every byte independently, including query prefix inside normal C1 data. */
wkmt2_profile_host_reset();forwarded_size=0;const char *bytes="C1,MT2?,crc\nMT2?\n";
for(size_t i=0;i<strlen(bytes);i++)wkmt2_profile_control(NULL,forward,(const uint8_t *)bytes+i,1,2);
assert(forwarded_size==strlen("C1,MT2?,crc\n")&&!memcmp(forwarded,"C1,MT2?,crc\n",forwarded_size));
usb_req_t r={.bmRequestType=0xa1,.bRequest=1,.wValue=0x03db,.wIndex=6,.wLength=128};void *p;size_t n;
assert(wkmt2_profile_setup(&r,&p,&n)==0&&n==76&&((uint8_t *)p)[0]==0xdb);
assert(wkmt2_profile_data(&r,p,n)==0); /* WCH also completes IN transfers. */
r.wLength=8;assert(wkmt2_profile_setup(&r,&p,&n)==0&&n==8);assert(wkmt2_profile_data(&r,p,n)==0);
r=(usb_req_t){.bmRequestType=0x81,.bRequest=6,.wValue=0x2200,.wIndex=6,.wLength=110};
assert(wkmt2_profile_setup(&r,&p,&n)==0&&n==110);assert(wkmt2_profile_data(&r,p,n)==0);
r.wValue=0x2100;r.wLength=9;assert(wkmt2_profile_setup(&r,&p,&n)==0&&n==9);assert(wkmt2_profile_data(&r,p,n)==0);
for(unsigned request=10;request<=11;request++){
r=(usb_req_t){.bmRequestType=0x21,.bRequest=(uint8_t)request,.wValue=1,.wIndex=6,.wLength=0};
assert(wkmt2_profile_setup(&r,&p,&n)==0&&n==0);assert(wkmt2_profile_data(&r,p,n)==0);}
for(unsigned request=2;request<=3;request++){
r=(usb_req_t){.bmRequestType=0xa1,.bRequest=(uint8_t)request,.wValue=0,.wIndex=6,.wLength=1};
assert(wkmt2_profile_setup(&r,&p,&n)==0&&n==1);assert(wkmt2_profile_data(&r,p,n)==0);}
r.bRequest=0x7f;assert(wkmt2_profile_setup(&r,&p,&n)==-1);assert(wkmt2_profile_data(&r,p,n)==-1);
r=(usb_req_t){.bmRequestType=0x21,.bRequest=9,.wValue=0x0302,.wIndex=6,.wLength=2};assert(wkmt2_profile_setup(&r,&p,&n)==0&&n==2);
uint8_t activation[]={2,1};assert(wkmt2_profile_data(&r,activation,2)==0&&enabled);
const uint8_t *input=wkmt2_profile_input(&n);assert(input&&n==12&&input[0]==2);assert(wkmt2_profile_input(&n)==input);
/* Disable before endpoint submit drops the cached (not yet sent) input. */
activation[1]=0;assert(wkmt2_profile_setup(&r,&p,&n)==0);assert(wkmt2_profile_data(&r,activation,2)==0&&!enabled);
assert(!wkmt2_profile_input(&n));
activation[1]=1;assert(wkmt2_profile_setup(&r,&p,&n)==0);assert(wkmt2_profile_data(&r,activation,2)==0&&enabled);
assert(wkmt2_profile_input(&n)&&n==12);
wkmt2_profile_input_done();assert(!wkmt2_profile_input(&n));
r.wLength=129;assert(wkmt2_profile_setup(&r,&p,&n)==-1);
r.wLength=2;activation[0]=3;assert(wkmt2_profile_setup(&r,&p,&n)==0);
assert(wkmt2_profile_data(&r,activation,2)==-1&&enabled);
wkmt2_profile_reset();assert(!enabled&&!wkmt2_profile_input(&n));puts("MT2_GLUE_TEST_PASS");}
'''
        self.assertIn("MT2_GLUE_TEST_PASS",self.compile_run("glue",body,[HERE/"mt2_glue.c"]))

    def test_generated_main_contains_bounded_paths_and_no_production_edit(self):
        main=(self.generated/"generated/main.c").read_text()
        self.assertNotIn("[2][7]",main)
        self.assertIn("i<(p?7:5)",main)
        self.assertIn("ep<=(p?7:6)",main)
        self.assertLess(main.index("const wk407_hid_packet *v="),main.index("wkmt2_profile_input(&n)"))
        self.assertLess(main.index("wkmt2_profile_input(&n)"),main.index("/* At most one 512-byte operation"))
        self.assertNotIn("wkmt2_profile",(profile.ROOT/"firmware/ch32v407/main.c").read_text())

    def test_single_port_probe_real_main_callbacks_queue_and_lifecycle(self):
        """Execute generated main + C callbacks + real Rust core with mock USB.

        No hardware APIs: these compile-time mocks record endpoint submissions.
        Production bridge/queue logic is linked, not reimplemented in the test.
        """
        work=self.work/"probe-integration";work.mkdir()
        candidate=work/"candidate"
        profile.generate(candidate,pointer_collections=True,absolute_mouse_logical=True,single_port_probe=True)
        rust=work/"rust-target"
        result=subprocess.run(["cargo","build","--offline","--release","--manifest-path",str(profile.PROBE_CORE/"Cargo.toml"),"--target-dir",str(rust)],text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        header=STUB.replace("typedef struct {int unused;} usbd_handle_t;","typedef struct {bool enumerated;unsigned port;} usbd_handle_t;")+r'''
typedef uint8_t usb_endp_t;
typedef int endp_resp_e;
#define ENDP_RESP_STALL 2
#define ENDP_RESP_NAK 1
#define USB_FALSE 0
#define USBD_CB_EVENT_RESET 0
#define USBD_ENDP_FEATURE_ZLP 1
static inline int usbd_is_enum(usbd_handle_t *h){return h->enumerated;}
int usbd_endp_open(usbd_handle_t *,unsigned,unsigned,unsigned);
void usbd_endp_close(usbd_handle_t *,unsigned);
int usbd_upload(usbd_handle_t *,uint8_t,const void *,unsigned);
static inline int usbd_download(usbd_handle_t *h,uint8_t ep,void *b,unsigned n){(void)h;(void)ep;(void)b;(void)n;return -1;}
int usbd_endp_set_response(usbd_handle_t *,uint8_t,int);
static inline int usbd_drv_init(usbd_handle_t *h){(void)h;return 0;}
static inline int usbd_enable(usbd_handle_t *h){(void)h;return 0;}
#define usbd_register_event_callback(...) ((void)0)
#define usbd_register_req_callback(...) ((void)0)
#define usbd_register_itf_callback(...) ((void)0)
#define usbd_register_data_callback(...) ((void)0)
#define usbd_open(...) ((void)0)
'''
        (work/"usb_driver.h").write_text(header)
        (work/"ch32v4x7.h").write_text(r'''
#pragma once
#include <stdint.h>
typedef struct {uint32_t CNT,CTLR,CMP;} mock_systick;
typedef struct {uint32_t MIS_ST,INT_FG,INT_EN;} mock_usb;
extern mock_systick mock_tick;
extern mock_usb mock_usb1,mock_usb2;
extern uint32_t SystemCoreClock;
#define SysTick (&mock_tick)
#define USBHS1D (&mock_usb1)
#define USBHS2D (&mock_usb2)
#define USBHS_UDMS_SUSPEND 2
#define USBHS_UDMS_SIE_FREE 8
#define USBHS_UDIF_BUS_RST 1
#define USBHS_UEP_T_DONE 128
#define USBHS_UEP_T_NAK_ACT 64
#define USBHS_UEP_T_RES_MASK 3
#define USBHS_UEP_T_RES_NAK 0
uint8_t mock_ep82_read(void);
void mock_ep82_write(uint8_t);
#define WKAP_EP82_CTRL_READ() mock_ep82_read()
#define WKAP_EP82_CTRL_WRITE(v) mock_ep82_write(v)
static inline void SystemCoreClockUpdate(void){}
''')
        (work/"ch32v4x7_usb.h").write_text('#pragma once\n')
        for p in [1,2]:
            (work/f"usbhs{p}_dcp.h").write_text(f'#pragma once\n#include "usb_driver.h"\nextern usbd_handle_t usbhs{p}d_handle;\nstatic inline void usbhs{p}_dch_init(void){{}}\nstatic inline void usbhs{p}_dch_interrupt(void){{}}\n')
        body=r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define main firmware_entry
#include "GENERATED_MAIN"
#undef main
int mock_speed=2;uint32_t SystemCoreClock=8000;
mock_systick mock_tick;mock_usb mock_usb1,mock_usb2;
usbd_handle_t usbhs1d_handle={false,0},usbhs2d_handle={true,1};
static unsigned uploads,closes,opens,upload_fail;
static uint8_t ctrl82;
static bool sdk_busy82,race82;
static unsigned abort_writes;
static uint8_t uploaded[512];static unsigned uploaded_size,uploaded_ep;
void usbd_endp_close(usbd_handle_t *h,unsigned ep){if(h->port==1&&ep==0x82)closes++;}
int usbd_endp_open(usbd_handle_t *h,unsigned ep,unsigned flags,unsigned size){
    (void)flags;(void)size;if(h->port==1&&ep==0x82){opens++;ctrl82=0;sdk_busy82=false;}return 0;
}
int usbd_endp_set_response(usbd_handle_t *h,uint8_t ep,int response){
    if(h->port==1&&ep==0x82){assert(response==ENDP_RESP_NAK);assert((ctrl82&3)==0);
        assert(!(ctrl82&128));assert(mock_usb2.MIS_ST&8);sdk_busy82=false;}return 0;
}
uint8_t mock_ep82_read(void){
    uint8_t value=ctrl82;
    /* The hardware may finish after the CPU's read but before its write. */
    if(race82){assert((ctrl82&3)==2);race82=false;ctrl82^=4;ctrl82|=128;mock_usb2.MIS_ST|=8;}
    return value;
}
void mock_ep82_write(uint8_t value){
    abort_writes++;
    /* W0C DONE/NAK_ACT; auto-toggle ignores CPU writes to the toggle bits. */
    ctrl82=(ctrl82&value&0xc0)|(ctrl82&0x0c)|(value&3);
}
int usbd_upload(usbd_handle_t *h,uint8_t ep,const void *b,unsigned n){
    if(upload_fail)return -1;
    if(h->port==1&&ep==0x82){assert(!sdk_busy82);assert(!(ctrl82&128));sdk_busy82=true;ctrl82=(ctrl82&~3)|2;}
    uploads++;uploaded_ep=ep;uploaded_size=n;memcpy(uploaded,b,n);return 0;
}
static void complete82(void){
    if(!(ctrl82&128)){assert((ctrl82&3)==2);ctrl82^=4;ctrl82|=128;}
    /* WCH handles a completed IN, invokes data_cb, then clears DONE. */
    data_cb(handles[1],0x82,NULL,0);ctrl82&=~131;sdk_busy82=false;
}
static uint32_t u32(const uint8_t *p){return p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static void put32(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(i*8));}
static usb_req_t request={0x21,9,0x0300,2,64};
static void command(unsigned op,unsigned point,uint32_t nonce,uint32_t seq){void *buf;size_t n;
    assert(!interface_setup(handles[1],&request,&buf,&n)&&n==64);
    uint8_t *b=buf;memset(b,0,64);memcpy(b,"WKAP",4);b[4]=1;b[5]=op;b[6]=point;put32(b+8,nonce);put32(b+12,seq);
    assert(!interface_data(handles[1],&request,buf,n));
}
static void status(uint8_t out[64]){void *buf;size_t n;usb_req_t r={0xa1,1,0x0300,2,64};
    assert(!interface_setup(handles[1],&r,&buf,&n)&&n==64);memcpy(out,buf,64);assert(!interface_data(handles[1],&r,buf,n));}
static void pass(unsigned dt){mock_tick.CNT+=dt;service();}
static void drain_normal(void){for(unsigned i=0;i<20;i++){pass(1);if(busy[1][1])data_cb(handles[1],0x81,NULL,0);if(busy[1][2])complete82();if(!bridge.hid.count&&!busy[1][1]&&!busy[1][2])break;}assert(!bridge.hid.count);}
static void arm_point(uint32_t nonce){command(1,0,nonce,1);pass(1);command(2,0,nonce,2);pass(1);assert(busy[1][2]&&tx_kind[1][2]==9);}
int main(void){
    handles[0]=&usbhs1d_handle;handles[1]=&usbhs2d_handle;
    mock_usb2.MIS_ST=USBHS_UDMS_SIE_FREE;
    wk407_init(&bridge);wk_setup_init(&setup,NULL,NULL);wkap_profile_reset();wkmt2_profile_reset();drain_normal();
    uint8_t s[64];void *buf;size_t n;
    /* Strict EP0 request, pointer and completion pairing. */
    for(unsigned field=0;field<5;field++){usb_req_t bad=request;
        if(field==0)bad.bmRequestType=0x20;if(field==1)bad.bRequest=1;if(field==2)bad.wValue=0x0301;if(field==3)bad.wIndex=1;if(field==4)bad.wLength=63;
        assert(wkap_profile_setup(&bad,&buf,&n,0)==USB_RST_FAILED);}
    assert(!wkap_profile_setup(&request,&buf,&n,0));memset(buf,0,64);
    assert(wkap_profile_data(&request,buf,63)==USB_RST_FAILED);
    assert(wkap_profile_data(&request,buf,64)==USB_RST_FAILED);
    assert(!wkap_profile_setup(&request,&buf,&n,0));wkap_profile_cancel_setup();assert(wkap_profile_data(&request,buf,64)==USB_RST_FAILED);
    assert(!wkap_profile_setup(&request,&buf,&n,0));uint8_t other[64]={0};assert(wkap_profile_data(&request,other,64)==USB_RST_FAILED);
    /* ARM/POINT cannot move in EP0; upload failure remains queued. */
    unsigned before=uploads;command(1,0,10,1);status(s);assert(s[5]==0&&uploads==before);pass(1);
    command(2,0,10,2);assert(uploads==before);upload_fail=1;pass(1);status(s);assert(s[5]==2&&u32(s+16)==0);upload_fail=0;pass(1);
    assert(uploaded_ep==0x82&&uploaded_size==8&&!memcmp(uploaded,(uint8_t[]){3,0,0,64,0,64,0,0},8));
    status(s);assert(s[5]==3&&u32(s+16)==2&&u32(s+20)==0);
    /* Probe completion must not pop a new ordinary HID queue item. */
    bridge.hid.count=1;bridge.hid.head=0;bridge.hid.item[0]=(wk407_hid_packet){.size=9,.endpoint=1,.bytes={1}};
    complete82();assert(bridge.hid.count==1);status(s);assert(u32(s+20)==2);drain_normal();
    status(s);assert(s[5]==0); /* ordinary queue invalidated the probe lease */
    /* Idle cancellation preserves DATA1, never close/open or another endpoint. */
    arm_point(11);uint32_t old_epoch=probe_tx_epoch,old_seq=probe_tx_seq;before=closes;unsigned old_opens=opens;
    uint8_t toggle=ctrl82&4;assert(toggle==4);pass(5000);
    assert(closes==before&&opens==old_opens&&!busy[1][2]&&!sdk_busy82&&(ctrl82&4)==toggle);
    status(s);assert(s[5]==0&&s[6]==6);
    arm_point(12);wkap_profile_done(old_epoch,old_seq);status(s);assert(s[5]==3&&u32(s+20)==0);
    command(3,0,12,3);pass(1);assert(!busy[1][2]);status(s);assert(s[5]==0&&s[6]==0&&u32(s+12)==3);
    /* SIE busy cannot release DMA ownership. Repeated passes do not spin or
     * accept another ARM. A completion racing NAK must stay pending until the
     * normal callback retires it; it must not pop the next ordinary report. */
    arm_point(18);mock_usb2.MIS_ST=0;command(3,0,18,3);before=uploads;pass(1);
    assert(busy[1][2]&&probe_abort_pending&&sdk_busy82&&uploads==before);
    status(s);assert(s[5]==0&&(u32(s+32)&8)); /* logically idle, hardware not retired */
    for(unsigned i=0;i<1000;i++)pass(1);
    command(1,0,19,1);pass(1);status(s);assert(s[5]==0&&s[6]==3);
    mock_usb2.MIS_ST=USBHS_UDMS_SIE_FREE;pass(1);assert(!busy[1][2]&&!probe_abort_pending);
    arm_point(20);race82=true;mock_usb2.MIS_ST=0;command(3,0,20,3);pass(1);
    assert(!race82&&busy[1][2]&&probe_abort_pending&&(ctrl82&128)&&sdk_busy82);
    bridge.hid.count=1;bridge.hid.head=0;bridge.hid.item[0]=(wk407_hid_packet){.size=8,.endpoint=2,.bytes={3,0,9,0,9,0,0,0}};
    before=uploads;pass(1);assert(uploads==before&&bridge.hid.count==1);
    complete82();assert(bridge.hid.count==1);pass(1);
    status(s);assert(!(u32(s+32)&8));
    assert(busy[1][2]&&tx_kind[1][2]==2&&!probe_abort_pending&&bridge.hid.count==1);
    assert(uploaded[2]==9&&uploaded[4]==9);complete82();assert(!bridge.hid.count);drain_normal();
    /* 1000 immediate cancel/re-arm cycles, both toggle values. No stale
     * completion or implicit DATA0 reset may survive into the next report. */
    for(unsigned i=0;i<1000;i++){
        arm_point(100+i);toggle=ctrl82&4;command(3,0,100+i,3);pass(1);
        assert(!busy[1][2]&&!sdk_busy82&&(ctrl82&4)==toggle);
    }
    assert(closes==0&&opens==old_opens); /* cancellation never reopens EP82 */
    /* All held-input fields and queued normal HID block ARM. */
    for(unsigned field=0;field<10;field++){bridge.buttons=bridge.modifiers=0;bridge.fn_down=bridge.release_pending=false;memset(bridge.keys,0,6);
        if(field==0)bridge.buttons=1;if(field==1)bridge.modifiers=1;if(field==2)bridge.fn_down=true;if(field==3)bridge.release_pending=true;if(field>=4)bridge.keys[field-4]=4;
        assert(wkap_profile_guards(&bridge,false,true,false)&WKAP_HELD_INPUT);
    }
    bridge.buttons=bridge.modifiers=0;bridge.fn_down=bridge.release_pending=false;memset(bridge.keys,0,6);
    usbhs1d_handle.enumerated=true;mock_usb1.MIS_ST=USBHS_UDMS_SUSPEND;command(1,0,13,1);pass(1);status(s);assert(s[5]==0&&s[6]==3&&(u32(s+32)&256));
    usbhs1d_handle.enumerated=false;mock_usb1.MIS_ST=0;
    /* Host reset revokes target-owned point; target reset/suspend/disconnect too. */
    arm_point(14);wk407_reset_begin(0);reset_cb(handles[0],0);before=closes;pass(1);assert(closes==before);drain_normal();
    arm_point(15);mock_usb2.MIS_ST=USBHS_UDMS_SUSPEND|USBHS_UDMS_SIE_FREE;pass(1);assert(!busy[1][2]);status(s);assert(s[5]==0);mock_usb2.MIS_ST=USBHS_UDMS_SIE_FREE;drain_normal();
    arm_point(16);usbhs2d_handle.enumerated=false;pass(1);assert(!busy[1][2]);usbhs2d_handle.enumerated=true;drain_normal();
    arm_point(17);command(3,0,17,3);mock_usb2.INT_FG=USBHS_UDIF_BUS_RST;
    before=abort_writes;pass(1);assert(busy[1][2]&&abort_writes==before);
    wk407_reset_begin(1);pass(1);assert(busy[1][2]&&abort_writes==before);
    reset_cb(handles[1],0);mock_usb2.INT_FG=0;drain_normal();status(s);assert(s[5]==0);
    puts("SINGLE_PORT_REAL_MAIN_RUST_CALLBACK_QUEUE_LIFECYCLE_PASS");
}
'''.replace("GENERATED_MAIN",str(candidate/"generated/main.c"))
        source=work/"integration.c";source.write_text(body)
        extra=[candidate/"generated/descriptors.c",HERE/"mt2_glue.c",HERE/"single_port_probe.c",HERE/"single_port_abort.c"]+[profile.ROOT/p for p in ["firmware/ch32v407/bridge.c","firmware/ch32v407/setup_msc.c","firmware/ch32v467_petros/setup_flash_none.c","firmware/main/wire_protocol.c"]]
        command=["clang","-std=c11","-Wall","-Wextra","-Wno-unused-function","-Werror","-I",str(work),"-I",str(HERE),"-I",str(profile.CORE/"include"),"-I",str(profile.ROOT/"firmware/ch32v407"),"-I",str(profile.ROOT/"firmware/main"),str(source),*[str(p) for p in extra],str(rust/"release/libwiredkvm_single_port_probe.a"),"-o",str(work/"integration")]
        result=subprocess.run(command,text=True,capture_output=True);self.assertEqual(result.returncode,0,result.stderr)
        result=subprocess.run([str(work/"integration")],text=True,capture_output=True);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn("SINGLE_PORT_REAL_MAIN_RUST_CALLBACK_QUEUE_LIFECYCLE_PASS",result.stdout)
        # Prove the completion-race assertion rejects a plain volatile RMW.
        # Only this retained temporary source is changed, never the real file.
        mutant=work/"abort-stale-zero-mutation.c"
        text=(HERE/"single_port_abort.c").read_text()
        marker=" | USBHS_UEP_T_DONE | USBHS_UEP_T_NAK_ACT"
        self.assertEqual(text.count(marker),1)
        mutant.write_text(text.replace(marker,""))
        mutated=[str(mutant) if x==str(HERE/"single_port_abort.c") else x for x in command]
        mutated[-1]=str(work/"integration-mutant")
        result=subprocess.run(mutated,text=True,capture_output=True);self.assertEqual(result.returncode,0,result.stderr)
        result=subprocess.run([mutated[-1]],text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0,"stale-zero mutation escaped the completion-race regression")
        main=(candidate/"generated/main.c").read_text()
        self.assertLess(main.index("const wk407_hid_packet *v="),main.index("wkap_profile_input(&n)"))
        self.assertLess(main.index("wkap_profile_input(&n)"),main.index("wkmt2_profile_input(&n)"))
        self.assertIn("usbd_is_enum(handles[0])||reset_pending[0]",main)
        invalid=work/"invalid"
        with self.assertRaisesRegex(ValueError,"requires absolute-mouse-logical"):profile.generate(invalid,single_port_probe=True)
        self.assertFalse(invalid.exists())

if __name__=="__main__":unittest.main(verbosity=2)
