
; minimal monitor for EhBASIC and 6502 simulator V1.05

; To run EhBASIC on the simulator load and assemble [F7] this file, start the simulator
; running [F6] then start the code with the RESET [CTRL][SHIFT]R. Just selecting RUN
; will do nothing, you'll still have to do a reset to run the code.

	.feature labels_without_colons
	.include "basic.asm"

; put the IRQ and MNI code in RAM so that it can be changed

IRQ_vec	= VEC_SV+2		; IRQ code vector
NMI_vec	= IRQ_vec+$0A	; NMI code vector

; setup for the 6502 simulator environment

IO_AREA		= $8800
ACIAdata	= IO_AREA	; simulated ACIA r/w port
ACIAstatus	= IO_AREA+1
ACIAcommand	= IO_AREA+2
ACIAcontrol	= IO_AREA+3

	CRTC_A	= $9000		; CRTC register select
	CRTC_C	= $9001		; CRTC register IO
	CADDR_L	= $E0		; Cursor address (low)
	CADDR_H	= $E1		; Cursor address (high)
	C_COL	= $E2		; Cursor column
	C_ROW	= $E3		; Cursor row
	COUTC	= $E4		; Temp storage for char out.
	TMPY	= $E5
	R_STRT	= $E6		; E6,E7 contains starting address of
				; current row

	N_ROWS	= 24
	N_COLS	= 40


; now the code. all this does is set up the vectors and interrupt code
; and wait for the user to select [C]old or [W]arm start. nothing else
; fits in less than 128 bytes

.segment "MONITOR"
	.org	$FC00		; pretend this is in a 1/8K ROM

; reset vector points here

RES_vec:
	CLD			; clear decimal mode
	LDX	#$FF		; empty stack
	TXS			; set the stack

	;; Initialize the CRTC
	LDA	#$01
	STA	CRTC_A
	LDA	#N_COLS		; 40 columns
	STA	CRTC_C
	LDA	#$06
	STA	CRTC_A
	LDA	#N_ROWS		; 24 rows
	STA	CRTC_C
	JSR	CLRVID
	;; TODO: Initialize params on CRTC

; Initialize the ACIA
ACIA_init:
	LDA	#$00
	STA	ACIAstatus		; Soft reset
	LDA	#$0B
	STA	ACIAcommand		; Parity disabled, IRQ disabled
	LDA	#$1E
	STA	ACIAcontrol		; Set output for 8-N-1 9600

; set up vectors and interrupt code, copy them to page 2

	LDY	#END_CODE-LAB_vec	; set index/count
LAB_stlp:
	LDA	LAB_vec-1,Y		; get byte from interrupt code
	STA	VEC_IN-1,Y		; save to RAM
	DEY				; decrement index/count
	BNE	LAB_stlp		; loop if more to do

; now do the signon message, Y = $00 here

LAB_signon:
	LDA	LAB_mess,Y	; get byte from sign on message
	BEQ	LAB_nokey	; exit loop if done

	JSR	V_OUTP		; output character
	INY			; increment index
	BNE	LAB_signon	; loop, branch always

LAB_nokey:
	JSR	V_INPT		; call scan input device
	BCC	LAB_nokey	; loop if no key

	AND	#$DF		; mask xx0x xxxx, ensure upper case
	CMP	#'W'		; compare with [W]arm start
	BEQ	LAB_dowarm	; branch if [W]arm start

	CMP	#'C'		; compare with [C]old start
	BNE	RES_vec		; loop if not [C]old start

	JMP	LAB_COLD	; do EhBASIC cold start

LAB_dowarm:
	JMP	LAB_WARM	; do EhBASIC warm start


ACIAout:

	PHA
@loop:	LDA	ACIAstatus
	AND	#$10
	BEQ	@loop		; Wait for buffer to empty
	PLA
	STA	ACIAdata
	RTS

;;; Byte out to the CRTC
;;;
;;; 1. Increment cursor position.
;;; 2. Scroll if necessary.
;;; 3. Store new cursor position in CRTC.

CRTCout:
	JSR	ACIAout		; Also echo to terminal for debugging.

	;; In parallel, we're maintaining two states:
	;;    - The address of the cursor, and
	;;    - The Column/Row of the cursor.
	;;
	;; The latter state is used to handle scrolling and
	;; for knowing how far to back up the cursor
	;; for a carriage-return.

	;; Backspace
	CMP	#$08
	BEQ	DO_BS
	;; Line Feed
	CMP	#$0a
	BEQ	DO_LF
	;; Carriage Return
	CMP	#$0d
	BEQ	DO_CR
	;; Any other character...
	CMP	#'a'
	STA	COUTC		; Store the character going out
	JSR	COUT1
	JSR	INC_CADDR
	INC	C_COL
	JSR	SET_CURSOR
	RTS

	;; Handle a back-space character.
DO_BS:	LDA	C_COL
	BNE	@l1		; Skip next bit
	LDA	#N_COLS-1
	STA	C_COL
	BNE	@l2
@l1:	DEC	C_COL
@l2:	JSR	DEC_CADDR	; Back up
	JSR	SET_CURSOR

@l3:	LDA	#$20
	STA	COUTC		; Echo a space ($20)
	JSR	COUT1
	RTS

DO_LF:	RTS			; Just swallow LF. CR emulates it.

DO_CR:	SEC
	LDA	CADDR_L		; 1. Carriage return to start of row.
	SBC	C_COL
	STA	CADDR_L
	LDA	CADDR_H
	SBC	#$00		; Will decrement H if carry was left
				; set.
	STA	CADDR_H

	;; 1. Are we on the last row? Scroll.
	LDA	C_ROW
	CMP	#N_ROWS-1
	BNE	@inc
	JSR	DO_SCROLL
	JMP	@lf
@inc:	INC	C_ROW

@lf:	CLC
	LDA	CADDR_L
	ADC	#$28		; Now add $28
	STA	CADDR_L
	LDA	CADDR_H
	ADC	#$00		; Will increment if carry was set
	STA	CADDR_H
	LDA	#$00		; Reset cursor row to 0
	STA	C_COL
	JSR	SET_CURSOR
	;; Move the cursor
	RTS

SET_CURSOR:
	LDA	#14
	STA	CRTC_A
	LDA	CADDR_H
	STA	CRTC_C
	LDA	#15
	STA	CRTC_A
	LDA	CADDR_L
	STA	CRTC_C
	RTS

	;; Clear the video window and put the cursor at the home
	;; position
CLRVID:
	LDA	#$70
	STA	CADDR_H
	LDA	#$00		; Set cursor start to $7000
	STA	CADDR_L
	STA	C_ROW
	STA	C_COL
	JSR	SET_CURSOR
	;; Fill with space character
	STY	TMPY
	LDA	#$20		; Space
	LDY	#$00
@l1:	STA	$7000,Y
	INY
	BNE	@l1
@l2:	STA	$7100,Y
	INY
	BNE	@l2
@l3:	STA	$7200,Y
	INY
	BNE	@l3
@l4:	STA	$7300,Y
	INY
	BNE	@l4
@l5:	STA	$7400,Y
	INY
	BNE	@l5
	LDY	TMPY

	RTS

	;; Handle a scroll request
DO_SCROLL:
	;; Copy $7028 through $70FF to $7000 through $70D7
	STY	TMPY		; Save Y
	LDY	#$00
@l1:	LDA	$7028,Y
	STA	$7000,Y
	INY
	BNE	@l1

@l2:	LDA	$7128,Y
	STA	$7100,Y
	INY
	BNE	@l2

@l3:	LDA	$7228,Y
	STA	$7200,Y
	INY
	BNE	@l3

@l4:	LDA	$7328,Y
	STA	$7300,Y
	INY
	BNE	@l4


	;; Now subtract 28 from C_ADDR
	SEC
	LDA	CADDR_L
	SBC	#$28
	STA	CADDR_L
	LDA	CADDR_H
	SBC	#$00
	STA	CADDR_H
	LDY	TMPY		; Restore Y
	RTS

	;; Decrement the cursor address
INC_CADDR:
	INC	CADDR_L
	BNE	@l1		; Did we increment to 0?
	INC	CADDR_H		; Yes, also increment high
@l1:	RTS

	;; Increment the cursor address
DEC_CADDR:
	CMP	CADDR_L		; Is low alrady 0?
	BNE	@l1
	DEC	CADDR_H		; Yes, decrement high
@l1:	DEC	CADDR_L
	RTS

COUT1:
	STY	TMPY
	LDY	#$00
	LDA	COUTC
	STA	(CADDR_L),Y
	LDY	TMPY
	RTS

;;;
;;; byte in from ACIA. This subroutine will also force
;;; all lowercase letters to be uppercase, because EhBASIC
;;; only understands upper-case tokens
;;;
ACIAin:
	LDA	ACIAstatus	; Read 6551 status
	AND	#$08		;
	BEQ	LAB_nobyw	; If rx buffer empty, no byte

	LDA	ACIAdata	; Read byte from 6551
	CMP	#'a'		; Is it < 'a'?
	BCC	@done		; Yes, we're done
	CMP	#'{'		; Is it >= '{'?
	BCS	@done		; Yes, we're done
	AND	#$5f		; Otherwise, mask to uppercase
@done:
	SEC			; Flag byte received
	RTS

LAB_nobyw:
	CLC			; flag no byte received
no_load:			; empty load vector for EhBASIC
no_save:			; empty save vector for EhBASIC
	RTS

; vector tables

LAB_vec:
	.word	ACIAin		; byte in from simulated ACIA
	.word	CRTCout		; byte out to simulated ACIA
	.word	no_load		; null load vector for EhBASIC
	.word	no_save		; null save vector for EhBASIC

; EhBASIC IRQ support

IRQ_CODE:
	PHA			; save A
	LDA	IrqBase		; get the IRQ flag byte
	LSR			; shift the set b7 to b6, and on down ...
	ORA	IrqBase		; OR the original back in
	STA	IrqBase		; save the new IRQ flag byte
	PLA			; restore A
	RTI

; EhBASIC NMI support

NMI_CODE:
	PHA			; save A
	LDA	NmiBase		; get the NMI flag byte
	LSR			; shift the set b7 to b6, and on down ...
	ORA	NmiBase		; OR the original back in
	STA	NmiBase		; save the new NMI flag byte
	PLA			; restore A
	RTI

END_CODE:


;;; CRTC row addresses: HIGH
CRA_HI:
	.byte	$70,$70,$70,$70,$70,$70,$70,$71
	.byte	$71,$71,$71,$71,$71,$72,$72,$72
	.byte	$72,$72,$72,$72,$73,$73,$73,$73


;;; CRTC row addresses: LOW
CRA_LO:
	.byte	$00,$28,$50,$78,$A0,$C8,$F0,$18
	.byte	$40,$68,$90,$B8,$E0,$08,$30,$58
	.byte	$80,$A8,$D0,$F8,$20,$48,$70,$98

; sign on string
LAB_mess:
	.byte	$0D,$0A,"SYMON (C) 2008-2014, SETH MORABITO"
	.byte   $0D,$0A,"ENHANCED 6502 BASIC 2.22 (C) LEE DAVISON"
	.byte   $0D,$0A,"[C]OLD/[W]ARM ?",$00


; system vectors

.segment "VECTORS"
	.org	$FFFA

	.word	NMI_vec		; NMI vector
	.word	RES_vec		; RESET vector
	.word	IRQ_vec		; IRQ vector
