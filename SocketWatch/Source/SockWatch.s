; SocketWatch.Source  0.06  23-06-2006

; This is the source code for version 0.06 of the SocketWatch module, originally by Dickon Hood.
; It's GNU GPL (see the file 'Licence').
; See the !Info file for more information.
;
; Frank de Bruijn, June 2006.
;

        GBLS    NAME
        GBLS    VERSION
        GBLS    DATE
NAME    SETS    "SocketWatch"
VERSION SETS    "0.06"
DATE    SETS    "23 Jun 2006"

wp              RN r12                           ; workspace pointer

X               * &20000                         ; bit 17

OS_Write0       * &02                            ; some SWIs
OS_NewLine      * &03
OS_Byte         * &06
OS_Module       * &1E
OS_Claim        * &1F
OS_Release      * &20
OS_ConvertHex8  * &D4
Socket_Ioctl    * &41212

iFlag26         * 1<<27                          ; IRQ flags
iFlag32         * 1<<7

                ^ 0
SockList        # 4                              ; workspace block : entry to linked list, defined below
WorkspaceSize   * @                              ;                   size of block

                ^ 0
SockNext        # 4                              ; socket structure: next in list
SockDescriptor  # 4                              ;                   the socket this describes
SockPollword    # 4                              ;                   pollword for this socket
SockBits        # 4                              ;                   bit to set (0..31) in the pollword if there's activity
SockSize        # 4                              ;                   size of an entry

SWIChunk        * &52280
ErrorChunk      * &815B00


        AREA    codeblock,CODE,READONLY


        ENTRY


ModuleHeader
        DCD     0                                ; no start code
        DCD     Initialise - ModuleHeader
        DCD     Finalise   - ModuleHeader
        DCD     0                                ; no service call handler
        DCD     Title      - ModuleHeader
        DCD     Help       - ModuleHeader
        DCD     Commands   - ModuleHeader
        DCD     SWIChunk
        DCD     SWIHandler - ModuleHeader
        DCD     SWITable   - ModuleHeader
        DCD     0                                ; no SWI decoding code
        DCD     0                                ; no Messages filename offset
        DCD     Flags      - ModuleHeader


Flags   DCD     1


Title   DCB     NAME,0


Help    DCB     NAME,9,VERSION," (",DATE,") � 2002 Dickon Hood",0
        ALIGN


; ------------------------------------------------------------------------------------------------------------------------------------
; Initialisation, finalisation - SVC mode
; ------------------------------------------------------------------------------------------------------------------------------------

Initialise                   ROUT
; Entry   :     r10 = pointer to environment string
;               r11 = I/O base of instantiation number (PRM 1-208)
;               r12 = pointer to private word (non zero? then after OS_Module 8)
;               r13 = pointer to supervisor stack
        STR     lr, [sp, #-4]!
        LDR     r2, [wp]
        TEQ     r2, #0                           ; don't (re)initialise if there's a value (pointer) in wp
        LDRNE   pc, [sp], #4
        MOV     r0, #6
        MOV     r3, #WorkspaceSize
        SWI     X+OS_Module
        LDRVS   pc, [sp], #4                     ; exit if no room in RMA
        STR     r2, [wp]
        MOV     wp, r2
        MOV     r0, #0
0000    STR     r0, [r2], #4                     ; clear workspace
        SUBS    r3, r3, #4
        BGT     %b0000
        MOV     r0, #16                          ; EventV
        ADR     r1, EventHandler
        MOV     r2, wp                           ; workspace pointer
        SWI     X+OS_Claim
        MOVVS   r3, r0
        BVS     %f0020
        MOV     r0, #14                          ; enable
        MOV     r1, #19                          ; Internet event
        SWI     X+OS_Byte
        LDRVC   pc, [sp], #4
        B       %f0010
Finalise                                         ; (PRM 1-209, 3-73)
; Entry   :     r10 = fatality indicator: 0=non fatal, 1=fatal
;               r11 = instantiation number
;               r12 = pointer to private word
;               r13 = pointer to supervisor stack
        STR     lr, [sp, #-4]!
        LDR     wp, [wp]
        LDR     r0, [wp, #SockList]
        TEQ     r0, #0
        ADRNE   r0, Finalise_Error
        BNE     %f0030
0010    MOV     r3, r0
        MOV     r0, #13                          ; disable
        MOV     r1, #19                          ; Internet event
        SWI     X+OS_Byte
0020    MOV     r0, #16                          ; EventV
        ADR     r1, EventHandler
        MOV     r2, wp                           ; workspace pointer
        SWI     X+OS_Release
        MOV     r0, #7
        MOV     r2, wp
        SWI     X+OS_Module                      ; free workspace
        SUBS    r0, r3, #0
        LDREQ   pc, [sp], #4                     ; V will be clear if Z is set
0030    CMPVC   r0, #1<<31
        CMNVC   r0, #1<<31                       ; set V
        LDR     pc, [sp], #4
Finalise_Error
        DCD     ErrorChunk+5
        DCB     "Still watching sockets - can't be killed yet",0
        ALIGN


; ------------------------------------------------------------------------------------------------------------------------------------
; Event handling - SVC or IRQ mode
; ------------------------------------------------------------------------------------------------------------------------------------

EventHandler                 ROUT
; Function:     Handle an event by checking the thread flag and then setting up a callback flag (pollword) to process it.
; Entry   :     r0 = event number
;               r1 = event reason
;               r2 = socket descriptor
;               interrupts disabled (PRM 1-146)
        TEQ     r0, #19
        MOVNE   pc, lr                           ; exit if not Internet event
        TEQ     r1, #1                           ; or not 'data waiting'
        TEQNE   r1, #2                           ; or not 'urgent data'
        TEQNE   r1, #3                           ; or not 'connection broken'
        MOVNE   pc, lr
        LDR     r0, [wp, #SockList]
        TEQ     r0, #0                           ; or not watching anything
        MOVEQ   r0, #19
        MOVEQ   pc, lr
        STMFD   sp!, {r1-r3, lr}
0000    LDR     lr, [r0, #SockDescriptor]
        TEQ     lr, r2                           ; else find the right descriptor(s)
        BNE     %f0010
        LDR     r2, [r0, #SockBits]
        LDR     lr, [r0, #SockPollword]
        LDR     r1, [lr]
        ORR     r1, r1, r2
        STR     r1, [lr]
0010    LDR     r0, [r0, #SockNext]
        TEQ     r0, #0
        BNE     %b0000
        MOV     r0, #19                          ; Internet event
        LDMFD   sp!, {r1-r3, pc}


; ------------------------------------------------------------------------------------------------------------------------------------
; SWI's - SVC mode
; ----------------
; Entry   :     r0-r9 = caller's values
;               r11   = five bottom bits of SWI number
;               r12   = pointer to private word
;               r13   = pointer to supervisor stack
;               r14   = return address as usual
; ------------------------------------------------------------------------------------------------------------------------------------

SWITable
        DCB     NAME,0
        DCB     "Register",0
        DCB     "Deregister",0
        DCB     "AtomicReset",0
        DCB     "AllocPW",0
        DCB     "DeallocPW",0
        DCB     0                                ; end of table
        ALIGN


SWIHandler                   ROUT
        LDR     wp, [wp]
        CMP     r11, #(%f0010-%f0000)/4
        ADDLE   pc, pc, r11, lsl #2
        B       %f0010
0000    B       SWI_Register
        B       SWI_Deregister
        B       SWI_AtomicReset
        B       SWI_AllocPW
        B       SWI_DeallocPW
0010    CMPVC   r0, #1<<31
        CMNVC   r0, #1<<31                       ; set V
        ADD     r0, pc, #0
        MOV     pc, lr
        DCD     &1E6
        DCB     "No such SWI",0
        ALIGN


SWI_Register                 ROUT
; Function:     Returns the pollword in r0; if this is zero on entry, it assigns one itself.
; Entry   :     r0 = pointer to pollword or zero
;               r1 = flag bits
;               r2 = socket descriptor
        STMFD   sp!, {r0-r4, lr}
        MOV     r4, r2                           ; socket descriptor
        TEQ     r0, #0
        MOVEQ   r3, #SockSize+4                  ; claim one word extra if the pollword is zero on entry
        MOVNE   r3, #SockSize
        MOV     r0, #6
        SWI     X+OS_Module
        BVS     %f0000
        LDR     r3, [wp, #SockList]              ; previous start entry or zero
        STR     r2, [wp, #SockList]              ; pointer to new block
        STR     r3, [r2, #SockNext]
        LDR     r0, [sp]
        TEQ     r0, #0
        ADDEQ   r0, r2, #SockSize                ; use word in structure if pollword was zero on entry
        STR     r0, [r2, #SockPollword]
        STR     r0, [sp]                         ; store pointer to pollword in r0 on stack
        STR     r1, [r2, #SockBits]
        STR     r4, [r2, #SockDescriptor]
        MOV     r0, r4
        LDR     r1, Ioctl_FIOASYNC
        ADR     r2, Ioctl_Arg                    ; 'On'
        SWI     X+Socket_Ioctl                   ; set FIOASYNC
        LDMVCFD sp!, {r0-r4, pc}
0000    ADD     sp, sp, #4                       ; discard stacked r0
        LDMFD   sp!, {r1-r4, pc}
Ioctl_FIOASYNC  DCD &8004667D
Ioctl_Arg       DCD 1


SWI_Deregister               ROUT
        STMFD   sp!, {r0-r4, lr}
        LDR     r4, [wp, #SockList]              ; get pointer to list
        MOV     r2, #0                           ; set 'last' to zero
0000    TEQ     r4, #0
        BEQ     %f0010
        LDR     r3, [r4, #SockDescriptor]
        TEQ     r0, r3                           ; sockets the same?
        LDREQ   r3, [r4, #SockPollword]
        TEQEQ   r1, r3                           ; same pollword?
        MOVNE   r2, r4
        LDRNE   r4, [r4, #SockNext]
        BNE     %b0000
        LDR     r3, [r4, #SockNext]
        TEQ     r2, #0                           ; was there a last one?
        STRNE   r3, [r2, #SockNext]
        STREQ   r3, [wp, #SockList]
        MOV     r2, r4
        MOV     r0, #7                           ; free the block
        SWI     X+OS_Module
        LDMFD   sp!, {r0-r4, pc}
0010    CMPVC   r0, #1<<31
        CMNVC   r0, #1<<31                       ; set V
        ADD     sp, sp, #4                       ; discard stacked r0
        ADD     r0, pc, #0
        LDMFD   sp!, {r1-r4, pc}
        DCD     ErrorChunk+4
        DCB     "Attempt to free an unregistered socket/pollword pair",0
        ALIGN


SWI_AtomicReset              ROUT
        TEQ     pc, pc
        BEQ     %f0000                           ; in 32 bit mode
        STMFD   sp!, {lr}
        TST     lr, #iFlag26
        TEQEQP  lr, #iFlag26                     ; IRQ off (no mode change, so no NOP required)
        LDR     lr, [r0]
        STR     r1, [r0]
        MOV     r0, lr
        LDMFD   sp!, {pc}^                       ; IRQ restored (also clears V as this was clear on entry)
0000    STMFD   sp!, {r2, lr}
        MRS     r2, cpsr
        ORR     lr, r2, #iFlag32
        MSR     cpsr_c, lr                       ; IRQ off
        LDR     lr, [r0]
        STR     r1, [r0]
        MOV     r0, lr
        MSR     cpsr_c, r2                       ; IRQ restored (also clears V as this was clear on entry)
        LDMFD   sp!, {r2, pc}


SWI_AllocPW
        STMFD   sp!, {r2-r3, lr}
        MOV     r0, #6
        MOV     r3, #4
        SWI     X+OS_Module
        MOVVC   r0, r2
        LDMFD   sp!, {r2-r3, pc}


SWI_DeallocPW                ROUT
        STMFD   sp!, {r0-r3, lr}
        MOV     r3, r0
        MOV     r1, r0
        LDR     r2, [wp, #SockList]
        TEQ     r2, #0
        BEQ     %f0010
0000    LDR     r0, [r2, #SockPollword]
        TEQ     r0, r1
        LDREQ   r0, [r2, #SockDescriptor]
        LDR     r2, [r2, #SockNext]
        BLEQ    SWI_Deregister
        TEQ     r2, #0
        BNE     %b0000
0010    MOV     r2, r3
        MOV     r0, #7
        SWI     X+OS_Module
        LDMVCFD sp!, {r0-r3, pc}
        ADD     sp, sp, #4
        LDMFD   sp!, {r1-r3, pc}


; ------------------------------------------------------------------------------------------------------------------------------------
; Commands - SVC mode
; -------------------
; Entry   :     r0 = pointer to command tail
;               r1 = number of parameters
;              r12 = pointer to private word
;              r13 = stack pointer
;              r14 = return address
; Exit    :     r0 = pointer to error block if V=1
;           r7-r11 = must be unaltered
; ------------------------------------------------------------------------------------------------------------------------------------

Commands
        DCB     NAME,0                           ; command name
        ALIGN
        DCD     0                                ; no command code
        DCD     0                                ; no information
        DCD     0                                ; no invalid syntax - use default
        DCD     Help_Name        - ModuleHeader

        DCB     NAME,"_DumpList",0               ; command name
        ALIGN
        DCD     Command_DumpList - ModuleHeader
        DCD     0                                ; no information
        DCD     Syntax_DumpList  - ModuleHeader
        DCD     Help_DumpList    - ModuleHeader

        DCD     0                                ; end of table

Help_Name
        DCB     "The ",NAME," module enables applications to do asynchronous socket",13,10
        DCB     "operations without null polls. See the !ReadMe file for more information.",13,10
        DCB     "This module is released under the terms of the GNU General Public License.",0

Help_DumpList
        DCB     "*",NAME,"_DumpList dumps the current list of watched sockets.",13,10
        DCB     "Useful for debugging purposes.",13,10
        DCB     "Syntax: "
Syntax_DumpList
        DCB     "*",NAME,"_DumpList",0

        ALIGN


Command_DumpList             ROUT
        LDR     wp, [wp]
        STR     lr, [sp, #-4]!
        LDR     r6, [wp, #SockList]
        TEQ     r6, #0
        BEQ     %f0010
        SUB     sp, sp, #12                      ; get some scratch space...
0000    ADR     r0, SWDL_x
        SWI     X+OS_Write0
        LDR     r0, [r6, #SockDescriptor]
        MOV     r1, sp
        MOV     r2, #9
        SWI     X+OS_ConvertHex8
        ADDVS   r0, r0, #4
        SWI     X+OS_Write0
        ADR     r0, SWDL_y
        SWI     X+OS_Write0
        LDR     r0, [r6, #SockPollword]
        MOV     r1, sp
        MOV     r2, #9
        SWI     X+OS_ConvertHex8
        ADDVS   r0, r0, #4
        SWI     X+OS_Write0
        ADR     r0, SWDL_z
        SWI     X+OS_Write0
        LDR     r0, [r6, #SockBits]
        MOV     r1, sp
        MOV     r2, #9
        SWI     X+OS_ConvertHex8
        ADDVS   r0, r0, #4
        SWI     X+OS_Write0
        SWI     X+OS_NewLine
        LDR     r6, [r6, #SockNext]
        TEQ     r6, #0
        BNE     %b0000
        ADD     sp, sp, #12
        LDR     pc, [sp], #4
0010    ADR     r0, SWDL_NowtString
        SWI     OS_Write0
        SWI     OS_NewLine
        LDR     pc, [sp], #4
SWDL_x  DCB     "Socket 0x",0
SWDL_y  DCB     ", pollword 0x",0
SWDL_z  DCB     ", bitmask 0x",0
        ALIGN
SWDL_NowtString
        DCB     "Nothing registered - nothing to do",0
        ALIGN


        DCB     10,10
        DCB     "Dickon Hood: dickon@fluff.org, dickon@oaktree.co.uk, in order of preference.",10
        DCB     "Frank de Bruijn: frank@aconet.org",10
        DCB     10
        ALIGN


        END
