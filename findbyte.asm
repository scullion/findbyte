%define shuffle_byte(s0, s1, s2, s3) (((s3 & 3) << 6) + ((s2 & 3) << 4) + ((s1 & 3) << 2) + (s0 & 3))

section .text

global Cpuid
global _Cpuid@4

; struct { int eax, ebx, ecx, edx; } (__stdcall Cpuid)(int param)
;
; We use stdcall because it's the only calling convention where the way of 
; returning structures is the same on VC and gcc (and Intel). cdecl doesn't work 
; because gcc expects the callee to remove the result pointer while VC doesn't. 
; fastcall doesn't work because the result pointer will be passed on the stack 
; by VC and in ECX by gcc.
Cpuid:
_Cpuid@4:
        push        ebx
        push        edi
        mov         edi, [esp + 12]
        mov         eax, [esp + 16]
        cpuid
        mov         [edi], eax
        mov         [edi + 4], ebx
        mov         [edi + 8], ecx
        mov         [edi + 12], edx
        mov         eax, edi
        pop         edi
        pop         ebx
        ret         8

global CpuidSupported
global @CpuidSupported@0

; bool (__fastcall CpuidSupported)(void)
CpuidSupported:        
@CpuidSupported@0:
        pushfd
        pop         ecx
        mov         eax, ecx
        xor         eax, 00200000h
        push        eax
        popfd
        pushfd
        pop         eax
        cmp         ecx, eax
        setne       al
        movzx       eax, al
        ret
        
global XmmEnabled
global @XmmEnabled@0

; bool (__fastcall XmmEnabled)(void)
XmmEnabled:
@XmmEnabled@0:
        push        ebp
        mov         ebp, esp
        sub         esp, 200h
        and         esp, 0FFFFFFF0h
        
        ; Save the image and remember the value written for xmm0[0:32].
        fxsave      [esp]
        mov         ecx, [esp + 160]
        
        ; Invert the value in the image and fxrstor.
        not         dword [esp + 160]
        fxrstor     [esp]
        
        ; Re-write the original value so we can tell if the following fxsave 
        ; modifies it.
        mov         [esp + 160], ecx
        fxsave      [esp]
        
        ; If the written value is the inverse of the original, the save worked.
        mov         edx, [esp + 160]
        not         edx
        xor         eax, eax
        cmp         ecx, edx
        sete        al
        
        mov         esp, ebp
        pop         ebp
        ret
        
        
        

global FindByteSSE
global @FindByteSSE@12

; int (__fastcall FindByteSSE)(buf, size, byte)
; ecx = buf, edx = size, byte on stack.
align 16
@FindByteSSE@12:
FindByteSSE:
        push        ebx   
        movzx       ebx, byte [esp + 8]     ; ebx = byte.
        push        esi
        push        edi        
        push        ebp
        
        mov         esi, edx                ; esi = negative count.
        neg         esi
        lea         edi, [ecx + edx]        ; edi = pointer to end of block.
        
        imul        ebx, 01010101h
        
        ; A lower threshold for using the SSE path makes rejection faster and
        ; finding slower for short strings. We use the minimum of 16 beacause 
        ; we favour fast rejection.
        cmp         edx, 64
        jge         .TestBlocks
        
        ; Test bytes up to the first word boundary.
    .TestLeadingBytes:
        test        eax, strict dword 11b    ; Long operand to pad loop entry.
        jz          .TestWordsAligned
        
        mov         ebp, 0FEFEFEFFh
        and         ecx, 3
        sub         esi, ecx                 ; Align the counter down.
        shl         ecx, 3
        shl         ebp, cl
        mov         eax, [edi + esi]
        xor         eax, ebx
        lea         ecx, [eax + ebp]
        not         eax
        and         ecx, 80808080h
        and         eax, ecx
        jnz         .FoundInWord
        add         esi, strict dword 4      ; Long operand to align loop entry.
       
       ; Test words using Alan Mycroft's trick, reading over the end of the string.
    .TestWordsAligned:
        test        esi, esi
        jns         .NotFound
        
        ; Prefixes and long operand to align the loop entry by 16.
    DS  mov         ebp, 80808080h
    DS  sub         esi, strict dword 4             
     
    .TestWordsAlignedLoop:
        add         esi, byte 4
        jns          .NotFound
        mov         eax, [edi + esi]
        xor         eax, ebx
        lea         ecx, [eax + 0FEFEFEFFh]
        not         eax
        and         ecx, ebp
        and         eax, ecx
        jz          .TestWordsAlignedLoop
        
    .FoundInWord:      
        ; Shift eax right and add 2 to esi if the match was not in the low 2 bytes.
        mov         ecx, eax
        shr         ecx, 16
        test        eax, 0FFFFh
        cmovz       eax, ecx
        lea         ecx, [esi + 2]
        cmovz       esi, ecx
        
        ; Add 1 to esi if  the match was not in the low byte.
        add         al, al
        sbb         esi, -1
        
        ; If the match position (esi) is now non-negative, the match was off the
        ; end of the string; return -1.
        test        esi, esi
        lea         eax, [edx + esi]
        mov         ecx, -1
        cmovns      eax, ecx
        
        mov         ebx, [esp + 12]
        mov         esi, [esp + 8]
        mov         edi, [esp + 4]
        mov         ebp, [esp]
        add         esp, 16
        ret         4
        
    .NotFound:
        or          eax, byte -1
        mov         ebx, [esp + 12]
        mov         esi, [esp + 8]
        mov         edi, [esp + 4]
        mov         ebp, [esp]
        add         esp, 16
        ret         4
        
        ; Load and test the first 16 bytes unaligned.
    .TestBlocks:
        movd        xmm1, ebx
        movups      xmm0, [ecx]
        pshufd      xmm1, xmm1, byte 0
        pcmpeqb     xmm0, xmm1
        pmovmskb    eax, xmm0
        test        eax, eax
        jnz         .TestLeadingBytes
        
        ; Make esi the index of the next 16-byte block.
        lea         esi, [ecx + 16]
        and         esi, 0FFFFFFF0h
        sub         esi, edi
        jmp         .TestBlocksAlignedLoopEntry
       
    .TestBlocksAlignedLoop:
        add         esi, 16
        cmp         esi, -16
        jg          .TestWordsAligned
    .TestBlocksAlignedLoopEntry:
        movaps      xmm0, [edi + esi]
        pcmpeqb     xmm0, xmm1
        pmovmskb    eax, xmm0
        test        eax, eax
        jz          .TestBlocksAlignedLoop
        jmp         .TestWordsAligned

  
global FindByteNoCaseSSE
global @FindByteNoCaseSSE@12

; int (__fastcall FindByteNoCaseSSE)(buf, size, byte)
; ecx = buf, edx = size, byte on stack.
align 16
@FindByteNoCaseSSE@12:
FindByteNoCaseSSE:
        push        ebx   
        movzx       ebx, byte [esp + 8]     ; ebx = byte.
        push        esi
        push        edi
        push        ebp
        
        ; Lowercase the character in bl, and if it's an alpha character put the
        ; bit-5 mask in ebp.
        xor         ebp, ebp
        mov         eax, ebx
        or          eax, 20h
        lea         esi, [eax - 'a']
        cmp         esi, 26
        mov         edi, 20202020h
        cmovb       ebx, eax
        cmovb       ebp, edi
        
        mov         esi, edx                ; esi = negative count.
        neg         esi
        lea         edi, [ecx + edx]        ; edi = pointer to end of block.
        
        imul        ebx, 01010101h
        
        ; A lower threshold for using the SSE path makes rejection faster and
        ; finding slower for short strings. We use the minimum of 16 beacause 
        ; we favour fast rejection.
        cmp         edx, 64
        jge         .TestBlocks
        
        ; Test bytes up to the first word boundary.
    .TestLeadingBytes:
        test        cl, byte 11b
        jz          .TestWordsAligned
        
        mov         eax, 0FEFEFEFFh
        and         ecx, 3
        sub         esi, ecx                 ; Align the counter down.
        shl         ecx, 3
        shl         eax, cl
        mov         ecx, [edi + esi]
        or          ecx, ebp
        xor         ecx, ebx
        lea         eax, [ecx + eax]
        not         ecx
        and         eax, 80808080h
        and         eax, ecx
        jnz         FindByteSSE.FoundInWord
        add         esi, 4
            
       ; Test words using Alan Mycroft's trick, reading over the end of the string.
    .TestWordsAligned:
        test        esi, esi
        jns         FindByteSSE.NotFound
        sub         esi, 4
        jmp         .TestWordsAlignedLoop
     
        align 16
    .TestWordsAlignedLoop:
        add         esi, byte 4
        jns         FindByteSSE.NotFound
        mov         eax, [edi + esi]
        or          eax, ebp
        xor         eax, ebx
        lea         ecx, [eax + 0FEFEFEFFh]
        not         eax
        and         ecx, 80808080h
        and         eax, ecx
        jz          .TestWordsAlignedLoop
        
        jmp         FindByteSSE.FoundInWord
       
        ; Load and test the first 16 bytes unaligned.
    .TestBlocks:
        movd        xmm2, ebp
        movd        xmm1, ebx
        movups      xmm0, [ecx]
        pshufd      xmm2, xmm2, byte 0
        pshufd      xmm1, xmm1, byte 0
        por         xmm0, xmm2
        pcmpeqb     xmm0, xmm1
        pmovmskb    eax, xmm0
        test        eax, eax
        jnz         .TestLeadingBytes
        
        ; Make esi the index of the next 16-byte block.
        lea         esi, [ecx + 16]
        and         esi, -10h
        sub         esi, edi
        jmp         .TestBlocksAlignedLoopEntry
       
    .TestBlocksAlignedLoop:
        add         esi, 16
        cmp         esi, -16
        jg          .TestWordsAligned
    .TestBlocksAlignedLoopEntry:
        movaps      xmm0, [edi + esi]
        por         xmm0, xmm2
        pcmpeqb     xmm0, xmm1
        pmovmskb    eax, xmm0
        test        eax, eax
        jz          .TestBlocksAlignedLoop
        jmp         .TestWordsAligned
