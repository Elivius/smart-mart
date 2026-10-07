# SmartMart – Assembly Interview Prep Guide

Written for someone who has never written assembly. Everything here is taken from **your actual file** `smart-mart.asm` (847 lines). Line numbers like `(L207)` point to it so you can open the file and look while you read.

**How to use this guide:** read Parts 1–4 first (concepts), then Part 5 (every instruction in your code), then Part 6 (walk through each routine), then drill Part 8 (likely questions). Part 9 lists the weak spots a lecturer might poke at, so you are not surprised.

---

## Part 1 – The 60-second summary (memorise this)

> "SmartMart is a point-of-sale and inventory program written in **32-bit x86 assembly (NASM)** for **Linux**. It talks to the OS with **`int 0x80` system calls** (`sys_read`, `sys_write`, `sys_exit`) – there is no C library. Products live in **parallel arrays** in the `.data` section. Money is stored as **integer cents** so there are no decimals. The main loop prints a menu, reads a number, and uses a **jump table** to call the routine for that menu option. Every routine saves registers with **`PUSHAD`/`POPAD`**, returns success/failure through the **carry flag**, and uses **repeated addition/subtraction** for line totals and discounts."

Features: add product, view catalogue, search (by number or partial name), process a sale (cart, discount, cash, change, receipt), restock, sales report, exit.

**Build and run** (your real file names):
```
nasm -f elf32 smart-mart.asm -o smart-mart.o     # assemble: text -> machine code (object file)
ld -m elf_i386 smart-mart.o -o smart-mart         # link: object file -> runnable program
./smart-mart
```
- `-f elf32` = produce a 32-bit Linux object file.
- `-m elf_i386` = tell the linker to make a 32-bit program.
- The header comment (L6–7) says `smartmart` without the hyphen – it's just a stale comment; your real file is `smart-mart`.

---

## Part 2 – Assembly mental model (the concepts behind the syntax)

### 2.1 What assembly is
Each assembly line is (almost always) **one CPU instruction**: `mnemonic destination, source`. There are no `if`, `while`, `for` or variables as in C. You build those yourself with **compare + jump**.

```
mov eax, 5        ; eax = 5          (destination FIRST, source SECOND)
add eax, 3        ; eax = eax + 3
```
Everything after `;` is a comment.

### 2.2 Registers = the CPU's tiny, super-fast variables
32-bit registers (4 bytes each):

| Register | Typical use in YOUR program |
|---|---|
| `EAX` | arithmetic accumulator, syscall number, **return value** |
| `EBX` | syscall arg 1; **product index** in sale/restock |
| `ECX` | syscall arg 2; **loop counter** (needed by `loop`) |
| `EDX` | syscall arg 3; scratch; remainder after `div` |
| `ESI` | source pointer / index |
| `EDI` | destination pointer |
| `ESP` | **stack pointer** (don't touch directly except `[esp+28]` trick) |
| `EBP` | not used |

Smaller parts: `EAX` (32-bit) contains `AX` (16-bit) which contains `AH` (high byte) and `AL` (low byte). Same for `EBX/BL`, `ECX/CL`, `EDX/DL`. You use `AL`, `AH`, `DL` to hold single characters (a char is 1 byte).

### 2.3 Memory and the three sections
```
section .data    initialised data  (strings, price/stock arrays you pre-filled)   (L67)
section .bss     UNinitialised data (reserved space, starts as zero)              (L171)
section .text    the actual code (instructions)                                   (L190)
```
- A **label** like `product_prices:` is just a name for an **address**.
- `[label]` (square brackets) means **"the value stored at that address"**.
- `label` without brackets means **"the address itself"**.

```
mov ecx, s_choice        ; ecx = ADDRESS of the text          (what PRINT does)
mov eax, [product_count] ; eax = the NUMBER stored there (4)
```
**This distinction is the #1 thing to be able to explain.**

### 2.4 Flags = the CPU's memory of the last comparison
`cmp` and arithmetic instructions set tiny 1-bit flags. Conditional jumps read them.

| Flag | Meaning | You use it for |
|---|---|---|
| **ZF** (zero) | result was 0 / values equal | `je`, `jne`, `jz`, `jnz` |
| **CF** (carry) | unsigned "borrow"/overflow | `jb`, `jae`, `ja`, and **as your success/failure return flag** (`jc`, `stc`, `clc`) |

### 2.5 The stack
A last-in-first-out region of memory. `push x` stores x; `pop x` gets it back (reverse order). `call` pushes the **return address** so `ret` knows where to go back. Your `PUSHAD/POPAD` save/restore all registers on it.

### 2.6 Signed vs unsigned jumps
You only use **unsigned** ones, because prices/stock are never negative:

| Jump | Means | Flag test |
|---|---|---|
| `jb` | jump if **b**elow (<) | CF=1 |
| `jae` | jump if **a**bove or **e**qual (>=) | CF=0 |
| `ja` | jump if **a**bove (>) | CF=0 and ZF=0 |
| `jbe` | (not used) below or equal | |
| `je` / `jz` | equal / zero | ZF=1 |
| `jne` / `jnz` | not equal / not zero | ZF=0 |
| `jc` | jump if carry set | CF=1 |
| `jmp` | always jump | – |

(Signed versions would be `jl`, `jg` – you don't use them.)

---

## Part 3 – NASM directives & syntax (non-instructions)

### 3.1 Constants – `EQU` (L24–40)
```
SYS_WRITE   EQU 4
MAX_PRODUCTS EQU 10
```
Like `#define`. The assembler replaces the name with the number. **Uses no memory.**

### 3.2 Defining data
| Directive | Size | Example in your code |
|---|---|---|
| `db` | 1 byte (define byte) | `db "Hello", 10` – text, `10` = newline |
| `dw` | 2 bytes | (not used) |
| `dd` | 4 bytes (define double-word) | `dd 500, 200, 150, 350` – the prices |
| `resb n` | reserve n bytes (BSS) | `input_buf: resb INPUT_MAX + 1` |
| `resd n` | reserve n × 4 bytes (BSS) | `cart_idx: resd MAX_CART_ITEMS` |
| `times n db 0` | repeat n times | pads unused array slots with zeros |

- `10` is ASCII **newline**; `0` is the **NUL terminator** (end-of-string).
- `$` = the **current address** being assembled. So `$ - s_banner` = "bytes since s_banner started" = the string's **length**. That's how `s_banner_len equ $ - s_banner` (L99) works without counting by hand.

### 3.3 Labels
- **Global labels:** `add_product:`, `main_loop:` – names of routines.
- **Local labels** start with a dot: `.room`, `.done`, `.copy`. They belong to the **previous non-dot label**, so many routines can each have their own `.done` without clashing.
- `global _start` (L191) exports the entry point; `ld` starts execution at `_start` (L195).

### 3.4 Size specifiers – `byte` / `dword`
When the CPU can't tell the size from a register, you must say it:
```
cmp  dword [product_count], 0      ; compare 4 bytes in memory with 0
cmp  byte  [input_buf], 0          ; compare 1 byte
inc  dword [product_count]
```
(`byte`=1, `dword`=4.) With a register on the other side (`mov eax, [x]`) it is inferred, so no specifier is needed.

### 3.5 Macros (L44–64) – templates the assembler pastes in
```
%macro STR 2+                    ; takes 2 or more parameters ('+' = last param eats the rest, commas included)
%1:         db %2                ; label = first param, data = the rest
%1_len      equ $ - %1           ; automatically creates  <label>_len
%endmacro
```
So `STR s_choice, "Enter choice: "` becomes:
```
s_choice:      db "Enter choice: "
s_choice_len   equ $ - s_choice
```
`NAME "Pen"` creates a **16-byte slot**: the text, then zero padding. `%%start` is a **macro-local label** (unique per use so the macro can be used many times). `times MAX_NAME_LEN - ($ - %%start) db 0` = "pad with zeros up to 16 bytes".

`PRINT label` (L56–64) expands to: save ECX/EDX, `mov ecx, label`, `mov edx, label_len`, `call print_str`, restore. **A macro is pasted inline at assembly time; a subroutine (`call`) exists once and is jumped to at runtime.**

---

## Part 4 – How your data is laid out

### 4.1 Parallel arrays (L70–82)
Three arrays, same index = same product:

```
index:            0          1       2        3             4..9
product_names:  "Notebook"  "Pen"  "Eraser" "Water Bottle"  (empty)   16 bytes each
product_prices: 500         200    150      350            0...      4 bytes each (cents)
product_stock:  10          20     5        4              0...      4 bytes each
product_count:  4
```
**Address of element i:**
- names: `product_names + i*16` (`MAX_NAME_LEN`=16)
- prices/stock: `product_prices + i*4`

That's why the code writes `[product_prices + esi*4]` – "base + index × scale", where **4 = size of a `dd`**.

### 4.2 Money = integer cents
RM 2.50 is stored as `250`. Benefits: no floating-point, only whole-number add/sub/compare. `MAX_PRICE EQU 99999` = RM 999.99, chosen so totals can't overflow 32 bits.

### 4.3 Menu jump table (L85–86)
```
menu_table: dd add_product, view_catalogue, search_product, process_sale
            dd restock_product, sales_report, quit
```
An array of **addresses of routines**. Menu choice N lives at entry N-1 (arrays start at 0), so:
```
call [menu_table + eax*4 - 4]       ; (L207)
```
Example: choice 3 → `menu_table + 3*4 - 4` = offset 8 = third entry = `search_product`. This replaces a long `if/else` chain with one line. (Say "jump table / dispatch table".)

### 4.4 Cart arrays (BSS L173–176)
`cart_idx`, `cart_qty`, `cart_total`, `cart_low` – up to 5 lines, also parallel arrays.

---

## Part 5 – Every instruction in your program

### Data movement
| Instruction | Meaning | Your example |
|---|---|---|
| `mov a, b` | a = b | `mov eax, SYS_WRITE` |
| `movzx a, b` | copy a small value into a bigger register, **zero-extended** | `movzx edx, byte [esi]` (L817) – load 1 char into a 32-bit reg |
| `lea a, [expr]` | load the **result of the address calculation** (no memory read) – used as a cheap calculator, **doesn't change flags** | `lea esi, [eax - 1]` (L344), `lea eax, [eax + eax*4]` (L823 = eax×5) |
| `push x` / `pop x` | put on / take off the stack | inside `PRINT` macro |
| `pushad` / `popad` | push/pop **all 8** general registers | first/last line of nearly every routine |
| `lodsb` | `al = [esi]`, then `esi++` (load string byte) | copy loops (L240, L727) |
| `stosb` | `[edi] = al`, then `edi++` (store string byte) | copy loops (L243, L732) |

`lodsb`/`stosb` move ESI/EDI **upward** only because of `cld` (clear direction flag) at the very start (L196). That's why `cld` is there.

### Arithmetic
| Instruction | Meaning | Example |
|---|---|---|
| `add a, b` | a += b | `add [order_total], eax` |
| `sub a, b` | a -= b | `sub eax, [order_total]` (change) |
| `inc a` / `dec a` | a++ / a-- | `inc dword [product_count]` |
| `imul d, src, imm` | signed multiply (3-operand form) | `imul edi, [product_count], MAX_NAME_LEN` (L235) – only used to compute **array addresses** |
| `div b` | **unsigned divide** `EDX:EAX ÷ b` → **EAX = quotient, EDX = remainder** | `div ebx` in `print_num`, `print_money` |
| `xor a, a` | a = 0 (shortest/fastest way to zero a register) | `xor ecx, ecx` |

**`div` rule:** before `div`, set `EDX = 0` (`xor edx, edx`) because the dividend is the 64-bit pair EDX:EAX. Forgetting it gives wrong answers or a crash.

### Comparison (set flags, change nothing else)
| Instruction | Meaning |
|---|---|
| `cmp a, b` | computes a − b, throws away the result, **keeps the flags** |
| `test a, a` | sets ZF if `a` is zero (`test eax, eax` ≡ "is eax zero?") |

Pattern everywhere:
```
cmp  eax, 7
ja   .invalid      ; jump if eax > 7
```

### Control flow
| Instruction | Meaning |
|---|---|
| `jmp label` | always jump |
| `jcc label` | jump if condition (`je jne jz jnz jb ja jae jc`) |
| `call label` | push return address, jump to routine |
| `ret` | pop return address, go back |
| `loop label` | `ecx--; if ecx != 0 jump` – a built-in counted loop (L244, L468, L733) |
| `int 0x80` | **software interrupt** = ask the Linux kernel to do a system call |

### Flag setting
| Instruction | Meaning |
|---|---|
| `stc` | set carry (CF=1) – your "error / found" signal |
| `clc` | clear carry (CF=0) – your "success / not found" signal |
| `cld` | direction flag = forward |

### Character tricks you use
- `'0'` is the number 48; `'A'`=65; `'Z'`=90. NASM lets you write the character.
- `add dl, '0'` turns digit 0–9 into text `'0'–'9'` (L748).
- `add al, 32` turns `'A'` into `'a'` (L404) – lowercase = uppercase + 32.
- `sub edx, '0'` then `cmp edx, 9 / ja` (L820–822) = "is it a digit 0–9?" in **one** comparison. If the char is below `'0'`, the subtraction wraps to a huge unsigned number, so `ja` also rejects it.

---

## Part 6 – Walk through the code

### 6.1 Calling convention you designed (header L13–20)
- **Every subroutine starts with `pushad` and ends with `popad`** → the caller's registers are never destroyed. This is the single most important design decision to mention.
- **Returning a value:** `pushad` pushes in this order: EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI, so the saved EAX sits at **`[esp+28]`**. `atoi` writes the result there (L834) so that `popad` *restores the answer into EAX*. 
  ```
  [esp+0]=EDI  +4=ESI  +8=EBP  +12=ESP  +16=EBX  +20=EDX  +24=ECX  +28=EAX
  ```
- **Returning success/failure:** use the **carry flag**. `popad` and `ret` do **not** modify flags, so CF survives (comment at L395).
- **Input parameters** are passed in registers (e.g. `ESI` = product index; `EAX` = number to print).

### 6.2 Entry point and main loop (L195–217)
```
_start:    cld ; PRINT banner
main_loop: PRINT menu, PRINT "Enter choice: "
           call read_number           ; EAX = number, CF=1 if not a number
           jc .invalid
           cmp eax,1 / jb .invalid    ; < 1
           cmp eax,7 / ja .invalid    ; > 7
           call [menu_table + eax*4 - 4]
           jmp main_loop              ; forever
```
`quit` (L213): prints "Goodbye!", then **`sys_exit(0)`**: `eax=1`, `ebx=0`, `int 0x80`. It never returns.

### 6.3 System calls (Linux 32-bit)
Put the call number in `EAX`, arguments in `EBX, ECX, EDX`, run `int 0x80`; result comes back in `EAX`.

| Syscall | EAX | EBX | ECX | EDX |
|---|---|---|---|---|
| `sys_exit` | 1 | exit code | | |
| `sys_read` | 3 | fd (0 = stdin) | buffer address | byte count |
| `sys_write` | 4 | fd (1 = stdout) | buffer address | byte count |

`print_str` (L713) = `sys_write` of ECX/EDX. `read_line` (L783) = `sys_read` of **1 byte at a time**, so it also works with piped input.

### 6.4 `read_line` (L783–807)
Loop: read 1 char → if EOF/error (`eax != 1`) jump to `quit`; if newline (10) → finish; if CR (13) → ignore; if buffer already has 63 chars → discard the extra; else store at `[input_buf + esi]`, `inc esi`. At the end write `0` (NUL) after the text. **Discarding excess characters** stops long input leaking into the next prompt.

### 6.5 `atoi` (L811–841) – text → number
For each character: `value = value*10 + digit`. Done **without `mul`**:
```
lea eax, [eax + eax*4]   ; eax = value*5
add eax, eax             ; eax = value*10
add eax, edx             ; + new digit
```
Trace "123": 0→1→12→123. Fails (CF=1) on: empty line, non-digit, or **more than 9 digits** (999,999,999 < 2³² ≈ 4.29 billion, so no overflow). `read_number` = `read_line` + `atoi`.

### 6.6 `print_num` (L741–758) – number → text
Repeated divide by 10; each **remainder is the next digit**, produced **right-to-left**, so the buffer is filled **backwards** from the end:
```
250 ÷ 10 = 25 r 0  -> '0'
 25 ÷ 10 =  2 r 5  -> '5'
  2 ÷ 10 =  0 r 2  -> '2'   (quotient 0 -> stop)   =>  "250"
```
Length = `end_of_buffer − start_pointer` (`sub edx, edi`). Then calls `print_str`. `do…while` style: a 0 still prints one digit.

### 6.7 `print_money` (L761–777)
`cents ÷ 100` → quotient = ringgit, remainder = sen. Prints `RM `, ringgit, `.`, then sen. If sen < 10 it prints a `0` first so 5 sen shows `.05`, not `.5`. Example: 205 → `RM 2.05`. It stores the sen in `ESI` because `PRINT`/`print_num` preserve ESI (pushad).

### 6.8 `print_name` (L722)
Copies the 16-byte slot to `name_tmp`, turning NUL padding into spaces (`mov al, ' '`) so columns line up, then prints.

### 6.9 Add product (L222–276)
1. Is `product_count < MAX_PRODUCTS` (10)? else "Catalogue is full".
2. Ask name; empty → ask again.
3. **Address of next free slot:** `edi = product_count*16 + product_names` (`imul` then `add`).
4. Copy up to 15 chars: `lodsb` / `test al,al` / `jz` / `stosb` / `loop`. 15 not 16 so the last byte stays NUL (slot was pre-zeroed).
5. Ask price (1–99999) → keep in **EBX** (survives later `call`s). Ask stock (0–999).
6. Store into arrays at index `product_count`, then `inc dword [product_count]`.
Bad input jumps back to re-ask (validation loops).

### 6.10 View catalogue / print row (L281–322)
Loop with ESI as index: `call print_product_row`, `inc esi`, `cmp esi,[product_count]`, `jb .row`. Row printing adds 1 to the index (humans count from 1), pads single digits with a space for alignment.

### 6.11 Search (L327–362) and `name_contains` (L366–396)
- Read a line, then try `atoi`. If **all digits** → treat as a product number (`lea esi,[eax-1]` converts to 0-based index). If not (`jc .by_name`) → substring search over every product.
- `name_contains` is a **nested loop**: outer = each start position in the name (`EBX`), inner = compare needle (`ESI`) against name (`EDI`) char by char, **case-insensitive** through `to_lower`. Reaching the needle's NUL means everything matched → `stc`; running out of name → `clc`.
- Note it uses `AL` for the name char, `AH` for the needle char, since `to_lower` only works on AL.

### 6.12 Process sale (L411–545) – biggest routine
1. Reset `cart_count` and `order_total`, show the catalogue.
2. **Add-item loop:** cart full (5) → go to checkout. Ask product number (0 = finish). Validate, convert to index (`dec eax`), keep in **EBX**. Ask quantity (0 = cancel this line).
3. **Stock reservation (L446–457):** `available = stock − quantity already in cart for this product`. A loop over cart lines subtracts matching quantities. This stops you selling the same product twice beyond stock. Request > available → "Not enough stock" and re-ask.
4. **Line total by repeated addition (L463–468):**
   ```
   mov ecx, edx          ; ecx = quantity
   xor eax, eax
   mov esi, price
   .mul_loop: add eax, esi ; loop .mul_loop      ; price added quantity times
   ```
   500 × 2 → 500 + 500 = 1000.
5. Append to the cart arrays, `add [order_total], eax`, `inc dword [cart_count]`.
6. **Checkout:** show subtotal, call `apply_discount`, show discount (if any) and total due, ask cash. 0 cancels; less than total → "Not enough cash" and re-ask. Otherwise `change = cash − total` (`sub`), then `update_stock`, `print_receipt`, `inc [txn_count]`, `add [total_revenue], order_total`.
**Stock is only reduced after payment succeeds**, so cancelling changes nothing.

### 6.13 `apply_discount` (L549–567) – repeated subtraction
Only if `order_total >= 5000` (RM 50). Take a copy in EAX; while `eax >= 500` do `eax -= 500; edx += 50`. So **every full RM 5.00 gives RM 0.50 off** (10%).
Worked example: total 5700 → 11 full blocks (5500), 200 left over → discount = 11×50 = **550**, due = 5700 − 550 = **5150**. Note the leftover 200 earns nothing.

### 6.14 `update_stock` (L570–589)
For each cart line: `stock -= qty`; if new stock ≤ 3 (`LOW_STOCK_LEVEL`) set `cart_low` = 1 (`cmp eax,3 / ja .next`). The receipt prints `[LOW STOCK]` for those lines.

### 6.15 `print_receipt` (L592–644)
Loop over cart lines: `qty x name  total`. Footer: subtotal (= `order_total + discount_amt`, because `order_total` has already had the discount subtracted), discount, total due, cash, change, thanks.

### 6.16 Restock (L649–689) and Sales report (L694–706)
Restock: choose product (0 cancels), enter units, `new = old + units`; if `> 999` → "exceeds the stock limit" and re-ask. Sales report just prints `txn_count` and `total_revenue`, which only change after a completed sale.

---

## Part 7 – Techniques to name-drop (and what they are)

| Technique | Where | One-line explanation |
|---|---|---|
| Jump/dispatch table | L85, L207 | array of routine addresses indexed by menu choice |
| Parallel arrays | L70–82 | several arrays share one index per record |
| Scaled-index addressing | everywhere | `[base + index*4]` |
| Register preservation | `pushad`/`popad` | each routine leaves caller's registers intact |
| Return via `[esp+28]` | `atoi` L834 | write into saved EAX so `popad` delivers it |
| Carry-flag return | `atoi`, `name_contains` | CF=1 failure/found, flag survives `popad`/`ret` |
| Repeated addition | L466 | multiplication without `mul` |
| Repeated subtraction | L556 | division-like discount without `div` |
| Shift-free ×10 | L823 | `lea` ×5 then `add` ×2 |
| Backwards digit buffer | `print_num` | digits come out last-to-first |
| Macros | `STR`, `NAME`, `PRINT` | assembler-time templates |
| Sentinel/NUL strings | everywhere | strings end with 0 |
| Input validation loops | every `read_number` | bad input → message → jump back to ask |

---

## Part 8 – Likely interview questions & model answers

**Q: What is a register? Why use them?**
A tiny storage cell inside the CPU. Much faster than memory. Arithmetic works on registers, so values are loaded in, processed, and stored back.

**Q: What does `mov eax, [product_count]` vs `mov eax, product_count` do?**
Brackets = read the **value stored** at that address (e.g. 4). No brackets = the **address** itself.

**Q: What does `int 0x80` do?**
Triggers a software interrupt so the Linux kernel performs a system call. `EAX` selects which one (1 exit, 3 read, 4 write); `EBX/ECX/EDX` hold its arguments.

**Q: Why `xor eax, eax` instead of `mov eax, 0`?**
Same result (zero), smaller instruction, conventional idiom. Note: it changes flags (sets ZF), `mov` doesn't.

**Q: What do `pushad`/`popad` do and why use them?**
Push/pop all general registers on the stack so a subroutine can freely use any register and the caller doesn't lose its values. Cost: slightly slower; benefit: simple, safe code.

**Q: How do you return a value if `popad` restores EAX?**
Overwrite the saved EAX copy on the stack, at `[esp+28]`, before `popad` (see `atoi`).

**Q: Why does CF still work after `popad` and `ret`?**
Neither instruction modifies flags, so the value set by `stc`/`clc` reaches the caller.

**Q: How does `call [menu_table + eax*4 - 4]` work?**
Indirect call through a table of addresses. Each entry is 4 bytes (`dd`); choice N is entry N−1; so the byte offset is `N*4 − 4`. It reads the address stored there and calls it.

**Q: Difference between `ja` and `jg`?**
`ja` = unsigned greater-than (CF/ZF); `jg` = signed. All values here are non-negative, so unsigned is right.

**Q: Why store money in cents?**
Avoids floating-point. Everything is whole numbers, so ADD/SUB/CMP are exact. 2.50 → 250.

**Q: Why cents instead of RM with a float/double?**
1. **Floats are inexact.** They store binary fractions, and 0.10 has no exact binary form (like 1/3 in decimal). `0.1 + 0.2 = 0.30000000000000004`. Errors build up over many additions, and checks like `cash >= total` or `change == 0` can fail by a tiny fraction. Integer cents are exact: `250 + 150` is always `400`.
2. **Floats are much harder in assembly.** Integers only need `add`/`sub`/`cmp` on normal registers. Floats need the separate x87 FPU stack (`fld`, `fadd`, `fstp`, `fcomi`) or SSE, plus a hand-written float-to-text routine, because there is no `printf`. Parsing "2.50" typed by the user would also need extra code.
3. **It fits the design.** The repeated-addition line total and repeated-subtraction discount only work cleanly on whole numbers.
4. **Trade-off:** conversion happens at the edges. `print_money` divides by 100 to show `RM 2.50`, and prices are entered in cents. `MAX_PRICE` (99999) keeps totals under 2³² so they can't overflow.

Short answer: *"Floating point can't represent decimals like 0.10 exactly, so errors build up and comparisons can fail. Integer cents make every calculation exact, keep the code to simple integer instructions instead of the FPU, and I only convert to RM x.xx when printing."*

**Q: How do you multiply without `mul`?**
Add the price once per unit (`add eax, esi` inside `loop`). 500 × 2 = 500 + 500.

**Q: How is the discount calculated?**
If total ≥ 5000 cents: subtract 500 repeatedly from a copy, adding 50 to the discount each time. Equivalent to 10% per full RM 5.

**Q: How do you convert the number 250 to the characters "250"?**
Repeatedly divide by 10; each remainder + `'0'` is an ASCII digit; store from the right end of the buffer backwards; print from the first digit to the end.

**Q: How do you convert text "123" to a number?**
For each char: subtract `'0'` to get the digit, `value = value*10 + digit`.

**Q: What does `loop` do? What's the danger?**
`dec ecx; jnz label`. If ECX is 0 on entry it wraps to 4 billion iterations. Your code guarantees ECX ≥ 1 (quantity ≥ 1 is checked first; the name copy uses 15).

**Q: What does `cld` do?**
Sets direction flag so `lodsb`/`stosb` move **forward** (ESI/EDI increase).

**Q: What are `.data`, `.bss`, `.text`?**
`.data` = initialised variables (stored in the file); `.bss` = reserved zeroed space (not stored in the file, saves size); `.text` = code.

**Q: How do you validate input?**
`read_number` → `atoi` returns CF=1 for non-digits/empty/too long. Then `cmp` for range checks. On failure, print an error and `jmp` back to the prompt.

**Q: How do you prevent overselling?**
Available = stock − units of that product already in the cart. Quantity > available is refused. Actual stock is only decremented after payment.

**Q: How does the search work?**
All digits → product number. Otherwise a case-insensitive substring search: try the needle at every start position in each name.

**Q: What happens if the input is longer than the buffer?**
`read_line` keeps reading but discards characters beyond 63, so nothing spills into memory or the next prompt.

**Q: What happens at end-of-file / Ctrl+D?**
`sys_read` returns 0 (not 1) → `jne quit` → program exits cleanly instead of looping.

**Q: Macro vs subroutine?**
Macro = text pasted at every use at assembly time (faster, bigger). Subroutine = one copy, reached with `call/ret` at run time.

---

## Part 9 – Honest weak spots (be ready, don't be surprised)

1. **"No MUL/DIV" claim.** The header says all calculation stays inside ADD/SUB/CMP (L10–11), but the code also uses **`div`** (in `print_num`/`print_money`, to split digits and ringgit/sen) and **`imul`** (to compute array addresses such as `index*16`). Be accurate: *"The business calculations – line totals, discount, change – use only add/sub/cmp. `div` and `imul` are only used for display formatting and address arithmetic."*
2. **`quit` is jumped to, not called, from `read_line`** (L793). That leaves the stack unbalanced, but it doesn't matter because the program exits immediately.
3. **Search by number takes priority:** typing `7` searches product #7, not a name containing "7".
4. **Capacity limits:** 10 products, 5 cart lines, 15-character names, price ≤ 99999, stock ≤ 999. Session data only – nothing is saved to disk, so everything resets on exit.
5. **Header typo:** build comment says `smartmart`, file is `smart-mart`.
6. **Stale-looking comment:** "10% discount" really means "RM 0.50 per full RM 5.00" – leftover amounts under RM 5 earn nothing, so it's *at most* 10%.
7. **32-bit only:** `int 0x80` is the 32-bit syscall interface. A 64-bit program would use `syscall` and different registers (`RAX`, `RDI`, `RSI`, `RDX`).

---

## Part 10 – One-page cheat sheet

```
mov a,b      a = b                       cmp a,b     compare (a-b), set flags
add a,b      a += b                      test a,a    is a zero?
sub a,b      a -= b                      jmp         always jump
inc/dec a    a++ / a--                   je/jne      equal / not equal
xor a,a      a = 0                       jb/jae      below / above-or-equal (unsigned)
lea a,[x]    a = address-calc (no read)  ja          above (unsigned)
movzx a,b    zero-extend load            jc          carry set
div b        EAX=EDX:EAX/b, EDX=rem      stc / clc   set / clear carry
imul d,s,n   d = s * n                   call / ret  subroutine
loop L       ecx--, jump if ecx != 0     pushad/popad  save/restore ALL regs
lodsb        al=[esi], esi++             int 0x80    system call
stosb        [edi]=al, edi++             cld         string ops go forward

Syscalls: eax=1 exit(ebx) | eax=3 read(ebx=fd,ecx=buf,edx=n) | eax=4 write(ebx=fd,ecx=buf,edx=n)
Memory:   [label]=value   label=address   [base+index*4]=array element (dd)
Stack after pushad: [esp+28] = saved EAX
```

---

## Part 11 – Practice drills (do these out loud)

1. Trace `atoi` on `"47"` line by line. *(0→4→47, CF=0)*
2. Trace `print_num` on `305`. *(305÷10 = 30 r5 →'5'; 30÷10 = 3 r0 →'0'; 3÷10 = 0 r3 →'3' → "305")*
3. What does `print_money` print for `5`? For `1050`? *(RM 0.05, RM 10.50)*
4. A cart totals 7300 cents. What's the discount and total due? *(14 blocks → 700 off → 6600)*
5. Which routine does choice `5` call? *(offset 5*4−4 = 16 → 5th entry → `restock_product`)*
6. Where is the name of product index 3 in memory? *(`product_names + 3*16` = +48)*
7. Why does `print_money` keep the sen in `ESI` and not `EAX`? *(`print_num` needs EAX for its own input; ESI survives because every routine uses pushad/popad)*
8. Explain, line by line, `.mul_loop` for price 350, qty 3. *(350→700→1050, ECX 3→2→1→0)*
9. Explain why `cmp edx, 9 / ja .bad` after `sub edx,'0'` also catches characters like `'/'`. *(`'/'`−`'0'` = −1 = 0xFFFFFFFF, unsigned huge)*
10. Point to the line that turns the stack's saved EAX into a return value and explain why it works. *(L834, `pushad` layout)*

**Tip for the interview:** if you're asked about a line, say *what it does → why it's there → what would break without it.* Open the file, point at the line, and trace one concrete example with real numbers. That's more convincing than reciting definitions.
