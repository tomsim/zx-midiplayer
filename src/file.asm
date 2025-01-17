; Page         128  +3
; 0 000
; 1 001        slow
; 2 010 0x8000
; 3 011        slow
; 4 100             slow
; 5 101 0x4000 slow slow
; 6 110             slow
; 7 111 altscr slow slow

file_pages:
    db #10, #14, #16, #13

file_base_addr equ #c000
file_page_size equ #4000


; IN  - HL - file position
; OUT -  A - data
; OUT - HL - next file position
; OUT -  F - garbage
file_get_next_byte:
    push bc                                                          ;
    push hl                                                          ;
    ld a, h                                                          ; compare requested page with current page
    and #c0                                                          ; ...
.pg:cp #0f                                                           ; ... self modifying code! see bellow and file_load
    jp z, .get                                                       ; ...
.switch_page:
    ld (.pg+1), a                                                    ;
    ld bc, #7ffd                                                     ;
    or a   : jp nz, 1f : ld a, (file_pages+0) : out (c), a : jp .get ;
1:  cp #40 : jp nz, 1f : ld a, (file_pages+1) : out (c), a : jp .get ;
1:  cp #80 : jp nz, 1f : ld a, (file_pages+2) : out (c), a : jp .get ;
1:                       ld a, (file_pages+3) : out (c), a : jp .get ;
.get:
    ld a, h                                                          ; position = position[5:0]
    and #3f                                                          ; ...
    ld h, a                                                          ; ...
    ld bc, file_base_addr                                            ; A  = *(base_addr + position)
    add hl, bc                                                       ; ...
    ld a, (hl)                                                       ; ...
    pop hl                                                           ;
    inc hl                                                           ; position++
    pop bc                                                           ;
    ret



trdos_sector_size            equ 256
trdos_max_files              equ 128
trdos_file_header_size       equ 16
trdos_catalogue_sectors      equ (trdos_max_files*trdos_file_header_size)/trdos_sector_size

trdos_var_next_sector        equ #5cf4
trdos_var_next_track         equ #5cf5

trdos_entrypoint_commandline equ #3d00
trdos_entrypoint_basic_cmd   equ #3d03
trdos_entrypoint_chan_in     equ #3d06
trdos_entrypoint_chan_out    equ #3d0d
trdos_entrypoint_exec_fun    equ #3d13 ; IN - C - function number
trdos_entrypoint_init        equ #3d21
trdos_entrypoint_jump        equ #3d2f

trdos_fun_reset_vg           equ #00
trdos_fun_select_drive       equ #01 ; IN - A - drive number
trdos_fun_select_track       equ #02 ; IN - A - track number
trdos_fun_select_sector      equ #03 ; IN - A - sector number
trdos_fun_set_buffer_addr    equ #04 ; IN - HL - buffer address
trdos_fun_read_block         equ #05 ; IN - HL - dst addr, IN - B - sectors count, IN - D - track number, IN - E - sector number
trdos_fun_write_block        equ #06 ; IN - HL - src addr, IN - B - sectors count, IN - D - track number, IN - E - sector number
trdos_fun_print_dir          equ #07 ; IN - A - channel number
trdos_fun_read_file_header   equ #08 ; IN - A - file number
trdos_fun_write_file_header  equ #09 ; IN - A - file number
trdos_fun_find_file          equ #0a ; OUT - C - file number
trdos_fun_write_code_file    equ #0b ; IN - HL - src addr, DE - len
trdos_fun_write_basic_file   equ #0c ;
trdos_fun_exit               equ #0d
trdos_fun_load_file          equ #0e ; IN - A == #00 - addr/len from cat ; A == #03 - HL - addr, DE - len ; A == #FF - HL - addr, len from cat
trdos_fun_delete_file        equ #12
trdos_fun_set_file_header    equ #13 ; IN - HL - src addr
trdos_fun_get_file_header    equ #14 ; IN - HL - dst addr
trdos_fun_scan_bad_track     equ #15 ; IN - D - sector number
trdos_fun_select_side_0      equ #16
trdos_fun_select_side_1      equ #17
trdos_fun_reconfig_floppy    equ #18


trdos_exec_fun:
    push iy                         ; im1 require IY
    ld iy, (var_basic_iy)           ;
    im 1                            ; trdos may crash with im != 1
    call trdos_entrypoint_exec_fun  ;
    ld a, high int_im2_vector_table ; set back IM2 interrupt table address (trdos may change it)
    ld i, a                         ; ...
    im 2                            ; ...
    ld (var_basic_iy), iy           ; save IY back
    pop iy                          ;
    ret                             ;


file_load_catalogue:
    xor a                                 ; set zero byte to first file name - same as clearing file list
    ld (file_buffer), a                   ; ...
    di                                    ;
    call trdos_entrypoint_init            ;
    ld c, trdos_fun_select_drive          ; select drive A
    ld a, 0                               ; ...
    call trdos_exec_fun                   ; ...
    ld c, trdos_fun_read_block            ; read file table
    ld hl, file_buffer                    ; ...
    ld b, trdos_catalogue_sectors         ; ...
    ld de, #0000                          ; ...
    call trdos_exec_fun                   ; ...
    call file_catalogue_optimize          ;
    call file_catalogue_format_extensions ;
    call file_catalogue_set_icons         ;
    ret

file_catalogue_optimize:          ; reorganize catalogue to skip all deleted files
    ld b, trdos_max_files         ;
    ld de, trdos_file_header_size ;
    ld hl, file_buffer            ; HL = pointer for entries_all
    ld ix, file_buffer            ; IX = pointer for entries_good
.loop:
    ld a, (hl)                    ;
    or a                          ; if first byte == #00 - no entry
    jr z, .bad_entry              ; ...
    dec a                         ; if first byte == #01 - deleted entry
    jr z, .bad_entry              ; ...
.good_entry:
    ld a, (hl)                    ; save good entry
    ld (ix), a                    ;
    inc hl                        ;
    inc ix                        ;
    dec e                         ;
    jr nz, .good_entry            ;
    ld e, trdos_file_header_size  ;
    djnz .loop                    ;
    jp .exit                      ;
.bad_entry:
    add hl, de                    ; HL += trdos_file_header_size
    djnz .loop                    ;
.exit:
    xor a                         ; place NULL byte to the last entry. This entry may be +1 byte above trdos_max_files*trdos_file_header_size
    ld (ix), a                    ; ... boundary. So file_buffer should be at least trdos_max_files*trdos_file_header_size+1 bytes
    ret                           ;

file_catalogue_format_extensions:
    ld b, trdos_max_files         ;
    ld de, trdos_file_header_size ;
    ld ix, file_buffer            ;
.loop:
    ld a, (ix+9)                  ; if 2nd and 3rd extensions symbols are in ascii range - assume extension is 3-chars-wide
    cp '0'                        ; ...
    jp c, .invalid_extension      ; ...
    cp 'z'+1                      ; ...
    jp nc, .invalid_extension     ; ...
    ld a, (ix+10)                 ; ...
    cp '0'                        ; ...
    jp c, .invalid_extension      ; ...
    cp 'z'+1                      ; ...
    jp nc, .invalid_extension     ; ...
    add ix, de                    ;
    djnz .loop                    ;
.invalid_extension:
    xor a                         ; if extension is 1-char wide - just write NULL to 2nd and 3rd bytes
    ld (ix+9), a                  ; ...
    ld (ix+10), a                 ; ...
    add ix, de                    ;
    djnz .loop                    ;
    ret                           ;

file_catalogue_set_icons:
    ld b, trdos_max_files         ;
    ld de, trdos_file_header_size ;
    ld ix, file_buffer            ;
.loop:
.check_mid_extension:
    ld a, (ix+8)                         ; if extension is "mid" - set appropriate icon
    cp 'm' : jr z, 1f                    ;
    cp 'M' : jr nz, .check_rmi_extension ;
1:  ld a, (ix+9)                         ;
    cp 'i' : jr z, 1f                    ;
    cp 'I' : jr nz, .check_rmi_extension ;
1:  ld a, (ix+10)                        ;
    cp 'd' : jr z, .set_icon             ;
    cp 'D' : jr z, .set_icon             ;
.check_rmi_extension:
    ld a, (ix+8)                         ; if extension is "rmi" - set appropriate icon
    cp 'r' : jr z, 1f                    ;
    cp 'R' : jr nz, .no_icon             ;
1:  ld a, (ix+9)                         ;
    cp 'm' : jr z, 1f                    ;
    cp 'M' : jr nz, .no_icon             ;
1:  ld a, (ix+10)                        ;
    cp 'i' : jr z, .set_icon             ;
    cp 'I' : jr z, .set_icon             ;
.no_icon:
    ld a, ' '                            ; if extension isn't recognized - set empty icon (space)
    jr .set                              ;
.set_icon:
    ld a, udg_melody                     ;
.set:
    ld (ix+11), a                        ;
    add ix, de                           ;
    djnz .loop                           ;
    ret                                  ;


; IN  - DE - entry number
; OUT -  F - NZ when ok, Z when not ok
; OUT - IX - pointer to 0-terminated string
file_menu_generator:
    xor a                     ; if (entry_number >= 128) - return not ok
    or d                      ; ...
    jp z, 1f                  ; ...
    xor a                     ; ... set Z flag
    ret                       ; ...
1:  ld a, e                   ; ...
    cp trdos_max_files        ; ...
    jp c, 1f                  ; ...
    xor a                     ; ... set Z flag
    ret                       ; ...
1:  push de                   ;
    sla e : rl d              ; entry_number = entry_number * 16
    sla e : rl d              ; ...
    sla e : rl d              ; ...
    sla e : rl d              ; ...
    ld hl, file_buffer        ; HL = file_buffer + entry_number * 16
    add hl, de                ; ...
    pop de                    ;
    ld a, (hl)                ; if first byte == NULL - return error (no entry)
    or a                      ; ...
    ret z                     ; ...
    ld ix, file_menu_string+2 ;
    push bc                   ;
    ld b, 8                   ;
.filenamecopy:                ;
    ld a, (hl)                ;
    ld (ix), a                ;
    inc hl                    ;
    inc ix                    ;
    djnz .filenamecopy        ;
    ld a, '.'                 ;
    ld (ix), a                ;
    inc ix                    ;
    ld b, 3                   ;
.extcopy:
    ld a, (hl)                ;
    ld (ix), a                ;
    inc hl                    ;
    inc ix                    ;
    djnz .extcopy             ;
    xor a                     ;
.filesize:
.icon:
    ld ix, file_menu_string   ;
    ld a, (hl)                ; icon
    ld (ix), a                ;
    ld a, ' '                 ; space
    ld (ix+1), a              ;
    pop bc                    ;
    or 1                      ; set NZ flag
    ret                       ;


; IN  - E - file number [0..127]
file_load:
.select_page
    ld a, (file_pages)                      ; select first page for file
    ld bc, #7ffd                            ; ...
    out (c), a                              ; ...
.load_file_params:
    sla e : rl d                            ; entry_number = entry_number * 16
    sla e : rl d                            ; ...
    sla e : rl d                            ; ...
    sla e : rl d                            ; ...
    ld ix, file_buffer                      ; IX = file_buffer + entry_number * 16
    add ix, de                              ; ...
    ld b, (ix+#d)                           ; sectors count
    ld e, (ix+#e)                           ; sector n
    ld d, (ix+#f)                           ; track n
    ld c, trdos_fun_read_block              ;
    ld hl, file_pages                       ; HL = pointer to pages table
.loop:
    push bc                                 ;
    push hl                                 ;
    ld a, file_page_size/trdos_sector_size  ; if (sectors_count > max) sector_count = max
    cp b                                    ; ...
    jp nc, 1f                               ; ...
    ld b, a                                 ; ...
1:  ld hl, file_base_addr                   ;
    call trdos_exec_fun                     ; memcpy( hl, de, b )
    pop hl                                  ;
    pop bc                                  ;
.loop_check_next_page:
    ld a, b                                 ; B = B - 64
    sub file_page_size/trdos_sector_size    ; ...
    ld b, a                                 ; ...
    jp c, .exit                             ; if (B <= 0) exit
    jp z, .exit                             ; ...
    ld d, b                                 ;
    inc hl                                  ; set next page
    ld a, (hl)                              ; ...
    ld bc, #7ffd                            ; ...
    out (c), a                              ; ...
    ld b, d                                 ; B = sectors left
    ld c, trdos_fun_read_block              ;
    ld de, (trdos_var_next_sector)          ; DE = next position
    jp .loop                                ;
.exit:
    ld a, #0f                               ; reset page
    ld (file_get_next_byte.pg+1), a         ; ...
    ret                                     ;
