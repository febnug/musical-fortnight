; bf2.asm — Brainfuck interpreter in x86_64 NASM for Linux
; -------------------------------------------------------
; Features
; - Accepts program as a literal argument argv[1] (preferred) or, if absent, reads program from stdin.
; - Filters out non-BF characters.
; - Preprocesses matching brackets with a simple stack for O(1) jumps.
; - 30,000-cell tape (wrap-around 0..255), stdin for ',', stdout for '.'
; - Minimal syscalls only (open/read/write/close/exit).
;
; Build:
;   nasm -felf64 bf2.asm -o bf2.o && ld -o bf2 bf2.o
; Run:
;   ./bf2 ">++++++++[<]>+."        # run BF program passed as argv[1]
;
; Tested on: Linux x86_64 (Ubuntu 22.04+)

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

%define O_RDONLY   0

%define PROGRAM_MAX  65536
%define TAPE_SIZE    30000

section .bss
  prog:          resb PROGRAM_MAX         ; filtered program bytes
  prog_len:      resq 1                   ; length after filtering
  tape:          resb TAPE_SIZE           ; 8-bit cells, zero-initialized by loader
  map_open2close:resd PROGRAM_MAX         ; map '[' index -> matching ']' index
  map_close2open:resd PROGRAM_MAX         ; map ']' index -> matching '[' index
  stack:         resd PROGRAM_MAX         ; simple dword stack for bracket positions
  stack_top:     resd 1                   ; index of top (count)

section .data
  usage: db "Usage: ./bf '<brainfuck-code>'  (or pipe program via stdin)", 10
  usage_len: equ $-usage
  err_unmatched_open: db "Error: unmatched '['", 10
  err_unmatched_open_len: equ $-err_unmatched_open
  err_unmatched_close: db "Error: unmatched ']'", 10
  err_unmatched_close_len: equ $-err_unmatched_close

section .text
  global _start

; ---------------------------------------
; write(rdi=fd, rsi=buf, rdx=len)
write:
  mov rax, SYS_WRITE
  syscall
  ret

; read(rdi=fd, rsi=buf, rdx=len) -> rax = bytes
read:
  mov rax, SYS_READ
  syscall
  ret

; exit(rdi=code)
exit:
  mov rax, SYS_EXIT
  syscall

; open(rdi=path, rsi=O_RDONLY)
open_ro:
  mov rax, SYS_OPEN
  syscall
  ret

; close(rdi=fd)
close_fd:
  mov rax, SYS_CLOSE
  syscall
  ret

; ---------------------------------------
; _start: read program (argv[1] as literal) or stdin, filter, preprocess, execute
_start:
  ; Zero prog_len and stack_top
  xor rax, rax
  mov [prog_len], rax
  mov dword [stack_top], 0

  ; raw _start stack: [argc][argv pointers...]
  pop rdi                ; argc
  mov r12, rdi           ; save argc
  mov r13, rsp           ; r13 = argv pointer (rsp now at argv[0])

  cmp r12, 1
  jg .read_arg_as_code
  jmp .read_from_stdin

; If argc > 1, treat argv[1] as the literal Brainfuck program
.read_arg_as_code:
  mov rsi, [r13+8]       ; rsi = pointer to argv[1] (null-terminated string)
  xor r8, r8             ; filtered length = 0
.read_arg_loop:
  mov al, [rsi]
  test al, al
  je .after_read_literal
  ; keep only ><+-.,[]
  cmp al, '>'
  je .keep_lit
  cmp al, '<'
  je .keep_lit
  cmp al, '+'
  je .keep_lit
  cmp al, '-'
  je .keep_lit
  cmp al, '.'
  je .keep_lit
  cmp al, ','
  je .keep_lit
  cmp al, '['
  je .keep_lit
  cmp al, ']'
  je .keep_lit
  jmp .skip_lit
.keep_lit:
  mov [prog + r8], al
  inc r8
.skip_lit:
  inc rsi
  jmp .read_arg_loop
.after_read_literal:
  mov [prog_len], r8
  jmp .after_read

.read_from_stdin:
  ; Read all from stdin (fd 0) into temp, filter on the fly
  xor r8, r8             ; filtered length
.stdin_loop:
  mov rdi, 0
  mov rsi, prog
  add rsi, r8            ; temporary space
  mov rdx, PROGRAM_MAX
  sub rdx, r8
  cmp rdx, 0
  je .after_read
  call read
  cmp rax, 0
  jle .after_read
  ; Filter rax bytes that just arrived
  mov rcx, rax           ; count
  mov rsi, prog
  add rsi, r8
  mov rdi, prog          ; dest always compacts at prog + current filtered len
  mov r9, r8             ; current filtered len
  add rdi, r9
.filter_chunk:
  cmp rcx, 0
  je .chunk_done
  mov al, [rsi]
  ; keep only ><+-.,[]
  cmp al, '>'
  je .keep
  cmp al, '<'
  je .keep
  cmp al, '+'
  je .keep
  cmp al, '-'
  je .keep
  cmp al, '.'
  je .keep
  cmp al, ','
  je .keep
  cmp al, '['
  je .keep
  cmp al, ']'
  je .keep
  jmp .skip
.keep:
  mov [rdi], al
  inc rdi
  inc r8                 ; filtered length++
.skip:
  inc rsi
  dec rcx
  jmp .filter_chunk
.chunk_done:
  jmp .stdin_loop

.after_read:
  mov [prog_len], r8

  ; Preprocess brackets to maps
  mov rbx, 0             ; ip over program during preprocessing
.pp_loop:
  mov rax, [prog_len]
  cmp rbx, rax
  jae .pp_done
  mov al, [prog + rbx]
  cmp al, '['
  je .pp_push
  cmp al, ']'
  je .pp_pop
  jmp .pp_next
.pp_push:
  mov ecx, [stack_top]
  mov [stack + rcx*4], ebx
  inc ecx
  mov [stack_top], ecx
  jmp .pp_next
.pp_pop:
  mov ecx, [stack_top]
  cmp ecx, 0
  je .unmatched_close
  dec ecx
  mov [stack_top], ecx
  mov edx, [stack + rcx*4]    ; matching '[' index
  ; map open->close and close->open
  mov dword [map_open2close + rdx*4], ebx
  mov dword [map_close2open + rbx*4], edx
  jmp .pp_next
.pp_next:
  inc rbx
  jmp .pp_loop

.pp_done:
  cmp dword [stack_top], 0
  jne .unmatched_open

  ; Execute
  xor r13, r13           ; data pointer index (0..TAPE_SIZE-1)
  xor rbx, rbx           ; instruction pointer (ip)

.exec_loop:
  mov rax, [prog_len]
  cmp rbx, rax
  jae .clean_exit
  mov al, [prog + rbx]
  cmp al, '>'
  je .op_right
  cmp al, '<'
  je .op_left
  cmp al, '+'
  je .op_plus
  cmp al, '-'
  je .op_minus
  cmp al, '.'
  je .op_dot
  cmp al, ','
  je .op_comma
  cmp al, '['
  je .op_lbrack
  cmp al, ']'
  je .op_rbrack
  jmp .ip_next

.op_right:
  inc r13
  cmp r13, TAPE_SIZE
  jb .ip_next
  mov r13, 0             ; wrap
  jmp .ip_next

.op_left:
  cmp r13, 0
  jne .left_dec
  mov r13, TAPE_SIZE-1
  jmp .ip_next
.left_dec:
  dec r13
  jmp .ip_next

.op_plus:
  mov rsi, tape
  add rsi, r13
  mov al, [rsi]
  inc al
  mov [rsi], al
  jmp .ip_next

.op_minus:
  mov rsi, tape
  add rsi, r13
  mov al, [rsi]
  dec al
  mov [rsi], al
  jmp .ip_next

.op_dot:
  mov rsi, tape
  add rsi, r13
  mov rdi, 1             ; stdout
  mov rdx, 1
  call write
  jmp .ip_next

.op_comma:
  mov rdi, 0             ; stdin
  mov rsi, tape
  add rsi, r13
  mov rdx, 1
  call read
  cmp rax, 1
  je .ip_next
  ; on EOF or error, write 0
  mov byte [rsi], 0
  jmp .ip_next

.op_lbrack:
  mov rsi, tape
  add rsi, r13
  mov al, [rsi]
  test al, al
  jnz .ip_next
  ; jump to matching ']' + 1
  mov edx, dword [map_open2close + rbx*4]
  mov ebx, edx
  jmp .ip_next_post

.op_rbrack:
  mov rsi, tape
  add rsi, r13
  mov al, [rsi]
  test al, al
  jz .ip_next
  ; jump back to matching '[' + 1
  mov edx, dword [map_close2open + rbx*4]
  mov ebx, edx
  jmp .ip_next_post

.ip_next:
  inc rbx
.ip_next_post:
  jmp .exec_loop

.unmatched_open:
  mov rdi, 2
  mov rsi, err_unmatched_open
  mov rdx, err_unmatched_open_len
  call write
  mov rdi, 1
  jmp exit

.unmatched_close:
  mov rdi, 2
  mov rsi, err_unmatched_close
  mov rdx, err_unmatched_close_len
  call write
  mov rdi, 1
  jmp exit

.usage_and_exit:
  mov rdi, 2
  mov rsi, usage
  mov rdx, usage_len
  call write
  mov rdi, 1
  jmp exit

.clean_exit:
  xor rdi, rdi
  jmp exit
