
.include "../inc/common.i"
.ifndef KPR_API_VERSION_NUMBER
  .define EQU     =
  .include "../inc/kipper_constants.i"
.endif

VARTAB	=	$2D		;BASIC variable table storage
ARYTAB	=	$2F		;BASIC array table storage
FREETOP	=	$33		;bottom of string text storage area
MEMSIZ	=	$37		;highest address used by BASIC
VARNAM = $45 ;current BASIC variable name
VARPNT = $47 ; pointer to current BASIC variable value

SETNAM	=	$FFBD
SETLFS	=	$FFBA 
OPEN	=	$FFC0
CHKIN	=	$FFC6
READST	=	$FFB7     ; read status byte
CHRIN	=	$FFCF     ; get a byte from file
CLOSE	=	$FFC3
MEMTOP  = 	$FE25                          
TXTPTR  = $7A            ;BASIC text pointer
IERROR  = $0300          
ICRUNCH = $0304          ;Crunch ASCII into token
IQPLOP  = $0306          ;List
IGONE   = $0308          ;Execute next BASIC token
                          
CHRGET  = $73            
CHRGOT  = $79            
CHROUT  = $FFD2          
GETBYT  = $B79E          ;BASIC routine
GETPAR  = $B7EB          ;Get a 16,8 pair of numbers
CHKCOM  = $AEFD          
NEW     = $A642          
CLR     = $A65E
NEWSTT	= $A7AE
GETVAR = $B0E7          ;find or create a variable
FRMEVL = $AD9E    ;evaluate expression
FRESTR = $B6A3  ;free temporary string
FRMNUM = $AD8A ;get a number
GETADR = $B7F7 ;convert number to 16 bit integer
INLIN = $A560 ; read a line from keyboard

VALTYP=$0D  ;00=number, $FF=string

LINNUM   = $14            ;Number returned by GETPAR

crunched_line      = $0200          ;Input buffer

.import copymem
.importzp copy_src
.importzp copy_dest
.import dhcp_init
.import ip65_init
.import cfg_get_configuration_ptr
.import ip65_process
.import ip65_error
.import cfg_ip
.import cfg_dns
.import cfg_gateway
.import cfg_netmask
.import icmp_ping
.import icmp_echo_ip
.import dns_set_hostname
.import dns_resolve
.import dns_ip

.import print_a
.import print_cr
.import dhcp_server
.import cfg_mac
.import cs_driver_name
.import get_key_if_available
.import timer_read
.import native_to_ascii
.import ascii_to_native

.import http_parse_request
.import http_get_value
.import http_variables_buffer


.zeropage
temp:	.res 2
temp2:	.res 2
pptr=temp
.segment "STARTUP"    ;this is what gets put at the start of the file on the C64
.word basicstub		; load address
basicstub:
	.word @nextline
	.word 2003    ;line number
	.byte $9e     ;SYS
	.byte <(((relocate / 1000) .mod 10) + $30)
	.byte <(((relocate / 100 ) .mod 10) + $30)
	.byte <(((relocate / 10  ) .mod 10) + $30)
	.byte <(((relocate       ) .mod 10) + $30)
	.byte 0
@nextline:
	.word 0  
relocate:  
  ldax  #end_of_loader
  stax  copy_src
  ldax  #main_start
  stax  copy_dest
  stax  MEMSIZ
FS=$8000-main_start  
  ldax  #FS

;copy memory
	sta end
	ldy #0

	cpx #0
	beq @tail

:	lda (copy_src),y
	sta (copy_dest),y
	iny
	bne :-
  inc copy_src+1    ;next page
  inc copy_dest+1  ;next page
	dex
	bne :-

@tail:
	lda end
	beq @done

:	lda (copy_src),y
	sta (copy_dest),y
	iny
	cpy end
	bne :-

@done:
  ldax #welcome_banner
  jsr print
  
	ldx	#5           ;Copy CURRENT vectors
@copy_old_vectors_loop:
	lda ICRUNCH,x
	sta	oldcrunch,x
	dex
	bpl	@copy_old_vectors_loop

	ldx	#5           ;Copy CURRENT vectors
install_new_vectors_loop:
	lda vectors,x
	sta	ICRUNCH,x
	dex
	bpl	install_new_vectors_loop
    
  ;BASIC keywords installed, now bring up the ip65 stack
    
  jsr ip65_init
@init_failed:  

  jsr $A644 ;do a "NEW"
  jmp $A474 ;"READY" prompt

welcome_banner:
.byte "### BASIC ON BAILS ###",13
.byte 0
end:  .res  1
end_of_loader:

.segment "MAINSTART"
main_start:

safe_getvar:      ;if GETVAR doesn't find the desired variable name in the VARTABLE, a routine at $B11D will create it
                  ;however that routine checks if the low byte of the return address of the caller is $2A. if it is,
                  ;it assumes the caller is the routine at $AF28 which just wants to get the variable value, and
                  ;returns a pointer to a dummy 'zero' pointer.
                  ;so if user code that is calling GETVAR happens to be compiled to an address $xx28, it will 
                  ;trigger this check, and not create a new variable, which (from painful experience) will create
                  ;a really nasty condition to debug!
                  ;so vector to GETVAR via here, so the return address seen by $B11D is here, and never $xx28
  jsr GETVAR
  rts
.code  

		
; CRUNCH -- If this is one of our keywords, then tokenize it
;
crunch:                    
	jsr jmp_crunch   ;First crunch line normally
    ldy #05          ;Offset for KERNAL
                          ;Y will contain line length+5
@loop:	
	sty temp
	jsr	isword		  ;Are we at a keyword?
	bcs	@gotcha
@next:
	jsr	nextchar
	bne	@loop	      ;Null byte marks end
	sta	crunched_line-3,Y       ;00 line number
	lda #$FF          ;'tis what A should be
	rts               ;Buh-bye
        
; Insert token and crunch line
@gotcha:
	ldx	temp         ;If so, A contains opcode
	sta crunched_line-5,X      
@move:
	inx
	lda crunched_line-5,Y      
	sta crunched_line-5,X      ;Move text backwards
	beq @next
	iny
	bpl @move
                          

; ISWORD -- Checks to see if word is
; in table.  If a word is found, then
; C is set, Y is one past the last char
; and A contains opcode.  Otherwise,
; carry is clear.
;
; On entry, TEMP must contain current
; character position.
;
isword:                    
	ldx #00          
@loop:
	ldy temp
@loop2:
	lda keywords,x
	beq	@notmine
	cmp	#$E0
	bcs	@done		;Tokens are >=$E0
	cmp crunched_line-5,Y      
	bne	@next
	iny   ;Success!  Go to next char
	inx
	bne	@loop2
@next:
	inx
	lda keywords,x	;Find next keyword
	cmp	#$E0
	bcc	@next
	inx
	bne	@loop       ;And check again
@notmine:
	clc
@done:	
	rts


; NEXTCHAR finds the next char
; in the buffer, skipping
; spaces and quotes.  On
; entry, TEMP contains the
; position of the last spot
; read.  On exit, Y contains
; the index to the next char,
; A contains that char, and Z is set if at end of line.

nextchar:
	ldy	temp
@loop:
	iny
	lda	crunched_line-5,Y
	beq	@done
	cmp #$8F         ;REM
	bne	@cont
	lda	#00
@skip:
	sta	temp2        ;Find matching character
@loop2:
	iny
	lda	crunched_line-5,Y
	beq	@done
	cmp	temp2
	bne	@loop2		;Skip to end of line
	beq	@loop
@cont:
	cmp #$20 		;space
	beq	@loop
	cmp #$22		;quote
	beq	@skip
@done:
	rts


;
; LIST -- patches the LIST routine
; to list our new tokens correctly.
;

list:
	cmp #$E0
	bcc	@notmine	;Not my token
	cmp	#HITOKEN
	bcs	@notmine
	bit $0F          ;Check for quote mode
	bmi	@notmine
	sec
	sbc	#$DF         ;Find the corresponding text
	tax
	sty	$49
	ldy	#00
@loop:
	dex
	beq	@done
@loop2:
	iny
	lda	keywords,y
	cmp	#$E0
	bcc	@loop2
	iny
	bne	@loop
@done:
  lda keywords,y
  cmp #$91    ;is it "ON"?
  bne @not_on
  lda #'O'
  jsr CHROUT
  lda #'N'
  bne @skip
  
@not_on:  
  cmp #$9B    ;is it "LIST"?

  bne @not_list
  lda #'L'
  jsr CHROUT
  lda #'I'
  jsr CHROUT
  lda #'S'
  jsr CHROUT  
  lda #'T'
  bne @skip
@not_list:
	lda	keywords,y
	bmi	@out  ;is it >=$80?
@skip:
	jsr	CHROUT
	iny
	bne	@done
@out:
	cmp	#$E0		         ;It might be BASIC token
	bcs	@cont
	ldy	$49          
@notmine:
	and #$FF
	jmp	(oldlist)
@cont:
	ldy $49          
	jmp $A700        ;Normal exit



;
; EXECUTE -- if this is one of our new 
; tokens, then execute it.
execute:                          
	jsr	CHRGET
execute_a:
  php
  cmp #':'  ;is it a colon?
  beq	execute;if so, skip over and go to next token
  cmp #$8B  ;is it 'IF'?
  bne @not_if
  lda #$E0  ;our dummy IF token
@not_if:  
	cmp	#$E0
	bcc	@notmine
	cmp #HITOKEN
	bcs	@notmine
	plp
	jsr	@disp
	jmp	NEWSTT
@disp:
	eor	#$E0
	asl		;multiply by 2
	tax
	lda	token_routines+1,x
	pha
	lda	token_routines,x
	pha
	jmp	CHRGET	;exit to routine (via RTS)
@notmine:
	plp
	cmp	#0 ;reset flags
	jmp $A7E7

;the standard BASIC IF routine calls the BASIC EXECUTE routine directly,
;without going through the vector. That means an extended keyword following THEN 
;will lead to a syntax error. So we have to reimpliment IF here
;this is taken from TransBASIC - The Transactor, vol 5, Issue 04 (March 1985) page 34  
if_keyword:  
  jsr FRMEVL      ;evaluate expression
  jsr CHRGOT  
  cmp #$89        ;is next token GOTO?
  beq @ok
  lda #$A7        ;is next token THEN
  jsr $AEFF       ;will generate SYNTAX ERROR if not  
@ok:
  jsr CHRGOT
  ldx $61         ;result of expression : 0 means false
  bne @expression_was_true
  jmp $A93B       ;go to REM implementation - skips rest of line
@expression_was_true:
  bcs @not_numeric;CHRGOT clears carry flag if current char is a number
  jmp $A8A0       ;do a GOTO
@not_numeric:  
  pla
  pla           ;pop the return address off the stack
  jsr CHRGOT
  jmp   execute_a ;execute current token  



;emit the 4 bytes pointed at by AX as dotted decimals
emit_dotted_quad:
  sta pptr
	stx pptr + 1
  ldy #0
  lda (pptr),y
  jsr emit_decimal 
  lda #'.'
  jsr emit_a

  ldy #1
  lda (pptr),y
  jsr emit_decimal 
  lda #'.'
  jsr emit_a

  ldy #2
  lda (pptr),y
  jsr emit_decimal 
  lda #'.'
  jsr emit_a

  ldy #3
  lda (pptr),y
  jsr emit_decimal
  
  rts

emit_decimal:  ;emit byte in A as a decimal number
  pha
  sta temp_bin   ;save 
  sed       ; Switch to decimal mode
  lda #0		; Ensure the result is clear
  sta temp_bcd
  sta temp_bcd+1
  ldx #8  ; The number of source bits		
  :
  asl temp_bin+0		; Shift out one bit
	lda temp_bcd+0	; And add into result
  adc temp_bcd+0
  sta temp_bcd+0
  lda temp_bcd+1	; propagating any carry
  adc temp_bcd+1
  sta temp_bcd+1
  dex		; And repeat for next bit
	bne :-
  
  cld   ;back to binary
      
  pla       ;get back the original passed in number
  bmi @emit_hundreds ; if N is set, the number is >=128 so emit all 3 digits
  cmp #10
  bmi @emit_units
  cmp #100
  bmi @emit_tens
@emit_hundreds:
  lda temp_bcd+1   ;get the most significant digit
  and #$0f
  clc
  adc #'0'
  jsr emit_a

@emit_tens:
  lda temp_bcd
  lsr
  lsr
  lsr
  lsr
  clc
  adc #'0'
  jsr emit_a
@emit_units:
  lda temp_bcd
  and #$0f
  clc
  adc #'0'
  jsr emit_a
  
  rts

print:
	sta pptr
	stx pptr + 1
	
@print_loop:
  ldy #0
  lda (pptr),y
	beq @done_print  
	jsr print_a
	inc pptr
	bne @print_loop
  inc pptr+1
  bne @print_loop ;if we ever get to $ffff, we've probably gone far enough ;-)
@done_print:
  rts


extract_string:
  jsr FRMEVL
  jsr FRESTR  ;if not string, will create type mismatch error
  sta param_length
  tay
  lda #0
  sta transfer_buffer,y  
  dey
@loop:
  lda ($22),y
  sta transfer_buffer,y  
  dey  
  bpl @loop
  jmp FRESTR  ;free up the temp string created by FRMEVL

;get a string value from BASIC command, turn into a 32 bit IP address,save it in the 4 bytes pointed at by AX
get_ip_parameter:
  stax  temp2
  jsr extract_string
  ldax #transfer_buffer
  jsr dns_set_hostname   
  
  bcs @error
  jsr dns_resolve
  bcc @ok
@error:  
  ldax  #address_resolution
  jmp print_error

@ok:
  ldax #dns_ip
  ldx #4
@copy_dns_ip:
  lda dns_ip,y 
  sta (temp2),y  
  iny
  dex  
  bne @copy_dns_ip  
  rts


reset_string:
  ldy #<string_buffer
  sty current_output_ptr  
  ldy #>string_buffer
  sty current_output_ptr+1
  rts
  
print_dotted_quad:
  jsr reset_string
  jsr emit_dotted_quad
make_null_terminated_and_print:  
  lda #0
  jsr emit_a
  ldax #string_buffer
  jmp print

print_mac:
  jsr reset_string
  jsr emit_mac
  jmp make_null_terminated_and_print

;print 6 bytes printed at by AX as a MAC address  
emit_mac:
  stax pptr  
  ldy #0
@one_mac_digit:
  tya   ;just to set the Z flag
  pha
  beq @dont_print_colon
  lda #':'
  jsr emit_a
@dont_print_colon:
  pla 
  tay
  lda (pptr),y
  jsr emit_hex
  iny
  cpy #06
  bne @one_mac_digit
  rts

emit_hex:
  pha  
  pha  
  lsr
  lsr
  lsr
  lsr
  tax
  lda hexdigits,x
  jsr emit_a
  pla
  and #$0F
  tax
  lda hexdigits,x
  jsr emit_a
  pla
  rts

print_hex:
  jsr reset_string
  jsr emit_hex
  jmp make_null_terminated_and_print

print_error:
  jsr print
  ldax #error
  jsr print
  lda ip65_error
  jsr print_hex
  jsr print_cr
  sec
  rts
  
get_optional_byte:  
  jsr CHRGOT
  beq @no_param ;leave X as it was
  jsr CHKCOM  ;make sure next char is a comma (and skip it)
  jsr CHRGOT
  beq @eol 
  jsr GETBYT  
@no_param:
  rts
@eol:
  jmp $AF08 ;SYNTAX ERROR
  
ipcfg_keyword:

  ldax #interface_type
  jsr print

  ldax #cs_driver_name
  jsr print
  jsr print_cr
  
  ldax #mac_address_msg
  jsr print
  ldax #cfg_mac
  jsr print_mac
  jsr print_cr

  ldax #ip_address_msg
  jsr print
  ldax  #cfg_ip
  jsr print_dotted_quad
  jsr print_cr

  ldax #netmask_msg
  jsr print
  ldax #cfg_netmask
  jsr print_dotted_quad
  jsr print_cr

  ldax #gateway_msg
  jsr print
  ldax  #cfg_gateway
  jsr print_dotted_quad
  jsr print_cr

  ldax #dns_server_msg
  jsr print
  ldax  #cfg_dns
  jsr print_dotted_quad
  jsr print_cr


  ldax #dhcp_server_msg
  jsr print
  ldax  #dhcp_server
  jsr print_dotted_quad
  jsr print_cr
  rts 

  
dhcp_keyword:
  jsr dhcp_init
  bcc @init_ok
  jsr ip65_init   ;if DHCP failed, then reinit the IP stack (which will reset IP address etc that DHCP messed with to default values)
  
@init_failed:  
  ldax  #dhcp
  jmp print_error
@init_ok:
 rts

ping_keyword:
  ldax  #icmp_echo_ip
  jsr get_ip_parameter
  bcc @no_error
  rts
@no_error:  

  ;is there an optional parameter?
  ldx #3
  jsr get_optional_byte
  stx ping_counter
  
  ldax #pinging
  jsr print
  ldax #dns_ip
  jsr print_dotted_quad
  jsr print_cr
  
@ping_loop:  
  jsr   icmp_ping
  bcs @error
  lda #'.'
@print_and_loop:  
  jsr print_a  
  lda $cb ;current key pressed
  cmp #$3F  ;RUN/STOP?
  beq @done
  dec ping_counter
  bne @ping_loop
@done:  
  jmp print_cr
@error:
  lda #'!'
  jmp @print_and_loop


myip_keyword:
  ldax #cfg_ip
  jmp get_ip_parameter

dns_keyword:
  ldax #cfg_dns
  jmp get_ip_parameter  

gateway_keyword:
  ldax #cfg_gateway
  jmp get_ip_parameter
  
netmask_keyword:
  ldax #cfg_netmask
  jmp get_ip_parameter  

  

skip_comma_get_integer:
  jsr CHRGOT
  jsr CHKCOM  ;make sure next char is a comma (and skip it)
get_integer:  
  jsr CHRGOT
  beq @eol 
  jsr FRMNUM
  jsr GETADR
  ldax  LINNUM
@no_param:
  rts
@eol:
  jmp $AF08 ;SYNTAX ERROR


hook_keyword:
  jsr extract_string
  ldax  #transfer_buffer
  jsr skip_comma_get_integer
  stax handler_address
  jsr find_hook
  bcc @existing_entry
  
  lda hooks
  cmp #MAX_HOOKS
  bmi @got_space
  ldx #$10 ;OUT OF MEMORY
  jmp $A437		;print error
@got_space:
  clc
  lda #0
  adc hooks
  adc hooks
  adc hooks 
  adc hooks
  adc hooks
  adc hooks 
  tay
  inc hooks
 @existing_entry: 
  ;y now points to free slot in hook table
  lda transfer_buffer
  sta hook_table,y
  lda transfer_buffer+1
  sta hook_table+1,y
  lda param_length
  sta hook_table+2,y
  lda hash
  sta hook_table+3,y
  lda handler_address
  sta hook_table+4,y
  lda handler_address+1
  sta hook_table+5,y
  rts


goto:
  sta  $14
  stx  $15
  jmp	$a8a3	;GOTO keyword


find_hook:
 jsr calc_hash
 ldy #0
 ldx hooks
 beq @done
@compare_one_entry:
 lda transfer_buffer
 cmp hook_table,y
 bne @nope
 lda transfer_buffer+1
 cmp hook_table+1,y
 bne @nope
 lda param_length
 cmp hook_table+2,y
 bne @nope
 lda hash
 cmp hook_table+3,y
 bne @nope
;found it!
 clc
 rts
@nope:
 dex
 beq @done
 iny
 iny
 iny
 iny
 iny
 iny
 
 bne @compare_one_entry
@done:
 sec
 rts
 
calc_hash:
 clc
 lda #0
 ldy param_length
 beq @done
@loop:
 adc transfer_buffer,y
 dey
 bne @loop
@done:
 sta hash
 rts 


yield_keyword:
  rts
gosub:
    
bang_keyword:
	jsr extract_string
	ldy #0
	sty	string_ptr
@loop:
	lda transfer_buffer,y
	jsr	putchar
	inc string_ptr
	ldy string_ptr
	cpy param_length
	bne	@loop
	rts

	
putchar:
	jmp	$ffd2


grok_keyword:
  ldax #http_buffer
  stax http_variables_buffer
  jsr extract_string
  ldax #transfer_buffer
  jsr http_parse_request
  lda #$02
  jsr http_get_value
  stax copy_src
  ldy #0
@copy_path:  
  lda (copy_src),y
  beq	@done
  sta transfer_buffer,y
  iny
  bne	@copy_path
@done:
  sty string_length
  lda #0
  sta transfer_buffer,y
  sty	param_length
  sty	tmp_length
  clc
  lda	#'P'
  sta VARNAM
  lda	#'A'+$80  
  jmp @set_var_value
@copy_vars:
  iny
  lda (copy_src),y
  beq	@last_var
  tax	;var name
  iny
  clc
  tya  
  adc	copy_src
  sta	copy_src
  bcc	:+
  inc	copy_src+1
:  
  ldy #0  
:  
  lda (copy_src),y
  beq	@end_of_var
  iny
  bne :-
@end_of_var:  
  sty	tmp_length
  clc
  stx VARNAM
  lda	#$80  
@set_var_value:  
  sta VARNAM+1
  jsr safe_getvar
  ldy	#0
  lda tmp_length
  sta (VARPNT),y
  iny
  lda copy_src
  sta (VARPNT),y
  iny
  lda copy_src+1
  sta (VARPNT),y
  ldy tmp_length
  jmp @copy_vars

  
 @last_var:
 
  jsr find_hook
  bcc @got_hook
  ldax default_line_number
  jmp goto
 @got_hook:
  lda hook_table+4,y
  ldx hook_table+5,y
  jmp	goto


httpd_keyword:
	jsr get_integer
	stax	httpd_port
	jsr skip_comma_get_integer
	stax	default_line_number
	rts
	
.rodata
vectors:
	.word crunch	
	.word list
	.word execute

; Keyword list
; Keywords are stored as normal text,
; followed by the token number.
; All tokens are >$80,
; so they easily mark the end of the keyword
hexdigits:
.byte "0123456789ABCDEF"

pinging:
.byte"PINGING ",0
interface_type:
.byte "INTERFACE   : ",0

mac_address_msg:
.byte "MAC ADDRESS : ", 0

ip_address_msg:
.byte "IP ADDRESS  : ", 0

netmask_msg:
.byte "NETMASK     : ", 0

gateway_msg:
.byte "GATEWAY     : ", 0
  
dns_server_msg:
.byte "DNS SERVER  : ", 0

dhcp_server_msg:
.byte "DHCP SERVER : ", 0


address_resolution:
.byte "ADDRESS RESOLUTION",0

tftp:
.byte "TFTP",0
dhcp:
.byte "DHCP",0

connect:
.byte "CONNECT",0

error:
.byte " ERROR $",0

disconnected:
.byte 13,"DIS"
connected_msg:
.byte "CONNECTED",13,0

keywords:                    
  .byte "IF",$E0  ;our dummy 'IF' entry takes $E0
   	.byte "IPCFG",$E1
   	.byte "DHCP",$E2
	.byte "PING",$E3
  	.byte "MYIP",$E4
  	.byte "NETMASK",$E5
  	.byte "GATEWAY",$E6
  	.byte "DNS",$E7
  	.byte "HOOK",$E8
  	.byte "YIELD",$E9
  	.byte "GROK",$EA
  	.byte "!",$EB
  	.byte "HTTPD",$EC
  	.byte $00					;end of list
HITOKEN=$ED

;
; Table of token locations-1
;
token_routines:
E0:	.word if_keyword-1
E1:	.word ipcfg_keyword-1
E2: .word dhcp_keyword-1
E3: .word ping_keyword-1
E4: .word myip_keyword-1
E5: .word netmask_keyword-1
E6: .word gateway_keyword-1
E7: .word dns_keyword-1
E8: .word hook_keyword-1
E9: .word yield_keyword-1
EA: .word grok_keyword-1
EB: .word bang_keyword-1
EC: .word httpd_keyword-1

.segment "SELF_MODIFIED_CODE"


jmp_crunch: .byte $4C          ;JMP
oldcrunch: 	.res 2             ;Old CRUNCH vector
oldlist:	.res 2             
oldexec:	.res 2           

emit_a:
current_output_ptr=emit_a+1
  sta $ffff
  inc string_length
  inc current_output_ptr
  bne :+
  inc current_output_ptr+1
:  
  rts

MAX_HOOKS=40

hook_table:
.res MAX_HOOKS*6
;format is:
; $00/$01 first 2 chars of hook name
; $02     length of name
; $03     hash of name
; $04/$05 line number that hook handler starts at

hooks: .byte 0

.bss
string_length: .res 1
param_length: .res 1
tmp_length: .res 1
temp_bin: .res 1
temp_bcd: .res 2
ping_counter: .res 1
http_buffer: .res 256
string_buffer: .res 128
transfer_buffer: .res 256
handler_address: .res 2
hash: .res 1
string_ptr: .res 1
httpd_port: .res 2
default_line_number: .res 2