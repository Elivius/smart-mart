; ============================================================================
; SmartMart - Point-of-Sale & Inventory Management System
; CT073-3-2 Computer System Low Level Techniques
; Platform : x86 32-bit (IA-32), NASM, Linux ELF32, system calls via int 0x80
;
; Build    : nasm -f elf32 smartmart.asm -o smartmart.o
;            ld -m elf_i386 smartmart.o -o smartmart
; Run      : ./smartmart
;
; Money is handled as unsigned integer CENTS (RM 2.50 = 250) so that every
; calculation stays inside ADD / SUB / CMP.
;
; Register convention (see SRS 5.6)
;   EAX  arithmetic accumulator, syscall number, return value
;   EBX  syscall arg 1 / product index inside sale & restock routines
;   ECX  syscall arg 2 / loop counter        EDX  syscall arg 3 / scratch
;   ESI  index or source pointer             EDI  destination pointer
;   Every subroutine wraps its body in PUSHAD/POPAD, so the caller's registers
;   survive. A routine that returns a value writes it into the saved-EAX slot
;   ([esp+28]) before POPAD; a routine that reports success/failure uses CF.
; ============================================================================

; ---------------------------------------------------------------- constants
SYS_EXIT            EQU 1
SYS_READ            EQU 3
SYS_WRITE           EQU 4
STDIN               EQU 0
STDOUT              EQU 1

MAX_PRODUCTS        EQU 10          ; catalogue capacity
MAX_NAME_LEN        EQU 16          ; bytes per name slot (15 chars + NUL)
MAX_CART_ITEMS      EQU 5           ; line items per transaction
MAX_PRICE           EQU 99999       ; cents (RM 999.99) - keeps totals < 2^32
MAX_STOCK           EQU 999         ; units per product
DISCOUNT_THRESHOLD  EQU 5000        ; cents: orders >= RM 50.00 earn a discount
DISCOUNT_BLOCK      EQU 500         ; every full RM 5.00 of spend ...
DISCOUNT_PER_BLOCK  EQU 50          ; ... earns RM 0.50 off (a 10% discount)
LOW_STOCK_LEVEL     EQU 3           ; stock at/below this is flagged
INPUT_MAX           EQU 63          ; characters kept from one input line
NUM_BUF_LEN         EQU 12          ; digits buffer for print_num

; ---------------------------------------------------------------- macros
; STR label, "text", 10   -> label: db ...   and   label_len = its length
%macro STR 2+
%1:         db %2
%1_len      equ $ - %1
%endmacro

; NAME "text" -> a MAX_NAME_LEN-byte, NUL-padded product-name slot
%macro NAME 1
%%start:    db %1
            times MAX_NAME_LEN - ($ - %%start) db 0
%endmacro

; PRINT label -> write a STR string to the screen (preserves ECX/EDX)
%macro PRINT 1
            push ecx
            push edx
            mov  ecx, %1
            mov  edx, %1_len
            call print_str
            pop  edx
            pop  ecx
%endmacro

; ============================================================================
section .data
; ============================================================================
; --- product catalogue: parallel arrays, seeded with 4 demo products --------
product_names:
            NAME "Notebook"
            NAME "Pen"
            NAME "Eraser"
            NAME "Water Bottle"
            times (MAX_PRODUCTS - 4) * MAX_NAME_LEN db 0
product_prices:                                 ; cents
            dd 500, 200, 150, 350
            times MAX_PRODUCTS - 4 dd 0
product_stock:
            dd 10, 20, 5, 4
            times MAX_PRODUCTS - 4 dd 0
product_count:  dd 4

; --- jump table for the main menu (option N -> entry N-1) -------------------
menu_table: dd add_product, view_catalogue, search_product, process_sale
            dd restock_product, sales_report, quit

; --- screen text -------------------------------------------------------------
s_banner:
            db  10
            db  "  ################################################", 10
            db  "  #                                              #", 10
            db  "  #                  SmartMart                   #", 10
            db  "  #       Point-of-Sale & Inventory System       #", 10
            db  "  #                                              #", 10
            db  "  ################################################", 10
            db  10
            db  "  Prices are entered in cents (250 = RM 2.50).", 10
s_banner_len equ $ - s_banner
s_menu:     db  10, "================================", 10
            db  "        SmartMart POS", 10
            db  "================================", 10
            db  "1. Add New Product", 10
            db  "2. View Product Catalogue", 10
            db  "3. Search Product", 10
            db  "4. Process Sale", 10
            db  "5. Restock Product", 10
            db  "6. View Sales Report", 10
            db  "7. Exit", 10
            db  "--------------------------------", 10
s_menu_len  equ $ - s_menu
STR s_choice,   "Enter choice: "
STR s_bad_choice, "Invalid choice - please enter a number from 1 to 7.", 10
STR s_bad_num,  "Invalid input - please enter a whole number.", 10
STR s_nl,       10
STR s_space,    " "
STR s_sp2,      "  "
STR s_dotsp,    ". "
STR s_times,    "x "
STR s_rm,       "RM "
STR s_dot,      "."
STR s_zero,     "0"
STR s_none,     "No products in the catalogue yet.", 10
STR s_cat_head, 10, "--- Product Catalogue ---", 10
STR s_stock_lbl, "  Stock: "
STR s_low,      "  [LOW STOCK]"
; add product
STR s_full,     "Catalogue is full - cannot add more products.", 10
STR s_ask_name, "Product name (max 15 characters): "
STR s_ask_price, "Unit price in cents (1 - 99999): "
STR s_bad_price, "Price must be between 1 and 99999 cents.", 10
STR s_ask_stock, "Initial stock (0 - 999): "
STR s_bad_stock, "Stock must be between 0 and 999.", 10
STR s_added,    "Product added.", 10
; search
STR s_ask_search, "Search by product number or part of the name: "
STR s_found,    "Match found:", 10
STR s_notfound, "No matching product found.", 10
; sale
STR s_ask_item, "Product number to buy (0 = finish): "
STR s_bad_item, "No such product number.", 10
STR s_ask_qty,  "Quantity (0 = cancel this line): "
STR s_bad_qty,  "Quantity must be a whole number.", 10
STR s_no_stock, "Not enough stock. Units still available: "
STR s_line_add, "  Line total: "
STR s_cart_full, "Cart is full - going to checkout.", 10
STR s_cancel,   "Sale cancelled - nothing was changed.", 10
STR s_subtotal, "Subtotal:       "
STR s_discount, "Discount:      -"
STR s_total_due, "Total due:      "
STR s_ask_cash, "Cash tendered (0 = cancel sale): "
STR s_short,    "Not enough cash - please enter at least the total due.", 10
; receipt
STR s_rcpt_head, 10, "------------ RECEIPT ------------", 10
STR s_rcpt_line, "---------------------------------", 10
STR s_cash,     "Cash tendered:  "
STR s_change,   "Change:         "
STR s_thanks,   "Thank you for shopping at SmartMart!", 10
; restock
STR s_ask_rs,   "Product number to restock (0 = cancel): "
STR s_ask_units, "Units to add: "
STR s_too_many, "That would exceed the stock limit of 999 units.", 10
STR s_restocked, "Stock updated.", 10
; report
STR s_rep_head, 10, "--- Sales Report (this session) ---", 10
STR s_rep_txn,  "Transactions completed: "
STR s_rep_rev,  "Total revenue:          "
STR s_bye,      10, "Goodbye!", 10

; ============================================================================
section .bss
; ============================================================================
cart_idx:       resd MAX_CART_ITEMS     ; product index of each cart line
cart_qty:       resd MAX_CART_ITEMS     ; quantity of each line
cart_total:     resd MAX_CART_ITEMS     ; line total (cents)
cart_low:       resd MAX_CART_ITEMS     ; 1 = product now at/below low stock
cart_count:     resd 1
order_total:    resd 1                  ; amount due for the current sale
discount_amt:   resd 1
cash_tendered:  resd 1
change_due:     resd 1
txn_count:      resd 1                  ; session totals for the sales report
total_revenue:  resd 1
input_buf:      resb INPUT_MAX + 1      ; one line of keyboard input (NUL-terminated)
char_buf:       resb 1                  ; single-byte I/O buffer
name_tmp:       resb MAX_NAME_LEN       ; padded copy of a name for printing
num_buf:        resb NUM_BUF_LEN        ; decimal digits for print_num

; ============================================================================
section .text
global _start
; ============================================================================

; ---------------------------------------------------------------- entry point
_start:
            cld                         ; string instructions (lodsb/stosb) count upward
            PRINT s_banner
main_loop:
            PRINT s_menu
            PRINT s_choice
            call read_number
            jc   .invalid               ; not a number
            cmp  eax, 1
            jb   .invalid               ; below the first option
            cmp  eax, 7
            ja   .invalid               ; above the last option
            call [menu_table + eax*4 - 4] ; jump-table dispatch: option N -> routine N
            jmp  main_loop              ; unconditional: redisplay the menu (the main loop)
.invalid:
            PRINT s_bad_choice
            jmp  main_loop

quit:                                   ; option 7: sys_exit(0) - never returns
            PRINT s_bye
            mov  eax, SYS_EXIT
            xor  ebx, ebx
            int  0x80

; ============================================================================
; MENU OPTION 1 - Add product
; ============================================================================
add_product:
            pushad
            cmp  dword [product_count], MAX_PRODUCTS
            jb   .room
            PRINT s_full                ; capacity check failed
            jmp  .done
.room:
.ask_name:
            PRINT s_ask_name
            call read_line
            cmp  byte [input_buf], 0
            je   .ask_name              ; an empty name is not allowed
            ; EDI = address of the next free name slot = names + count * 16
            imul edi, [product_count], MAX_NAME_LEN
            add  edi, product_names
            mov  esi, input_buf
            mov  ecx, MAX_NAME_LEN - 1  ; leave room for the NUL (slot is pre-zeroed)
.copy:
            lodsb
            test al, al
            jz   .name_done             ; end of typed text
            stosb
            loop .copy
.name_done:
.ask_price:
            PRINT s_ask_price
            call read_number
            jc   .bad_price
            cmp  eax, 1
            jb   .bad_price
            cmp  eax, MAX_PRICE
            ja   .bad_price
            mov  ebx, eax               ; EBX = validated price (survives later calls)
            jmp  .ask_stock
.bad_price:
            PRINT s_bad_price
            jmp  .ask_price
.ask_stock:
            PRINT s_ask_stock
            call read_number
            jc   .bad_stock
            cmp  eax, MAX_STOCK
            ja   .bad_stock
            mov  esi, [product_count]   ; index of the new record
            mov  [product_prices + esi*4], ebx
            mov  [product_stock  + esi*4], eax
            inc  dword [product_count]  ; the ADD-to-count from the proposal
            PRINT s_added
            jmp  .done
.bad_stock:
            PRINT s_bad_stock
            jmp  .ask_stock
.done:
            popad
            ret

; ============================================================================
; MENU OPTION 2 - View catalogue (loop over every stored product)
; ============================================================================
view_catalogue:
            pushad
            cmp  dword [product_count], 0
            jne  .have
            PRINT s_none
            jmp  .done
.have:
            PRINT s_cat_head
            xor  esi, esi               ; ESI = product index
.row:
            call print_product_row
            inc  esi
            cmp  esi, [product_count]
            jb   .row                   ; loop until every product is shown
.done:
            popad
            ret

; ESI = 0-based product index. Prints "N. name  RM x.xx  Stock: n"
print_product_row:
            pushad
            mov  ebx, esi               ; EBX = index (ESI is reused as a pointer below)
            mov  eax, ebx
            inc  eax                    ; humans count from 1
            cmp  eax, 10
            jae  .wide
            PRINT s_space               ; align 1-digit numbers with 2-digit ones
.wide:
            call print_num
            PRINT s_dotsp
            imul esi, ebx, MAX_NAME_LEN
            add  esi, product_names
            call print_name
            PRINT s_sp2
            mov  eax, [product_prices + ebx*4]
            call print_money
            PRINT s_stock_lbl
            mov  eax, [product_stock + ebx*4]
            call print_num
            PRINT s_nl
            popad
            ret

; ============================================================================
; MENU OPTION 3 - Search by number or by (part of) name
; ============================================================================
search_product:
            pushad
            cmp  dword [product_count], 0
            jne  .ask
            PRINT s_none
            jmp  .done
.ask:
            PRINT s_ask_search
            call read_line
            cmp  byte [input_buf], 0
            je   .done                  ; nothing typed: back to the menu
            call atoi
            jc   .by_name               ; not all digits -> treat as a name fragment
            cmp  eax, 1                 ; numeric -> product number lookup
            jb   .notfound
            cmp  eax, [product_count]
            ja   .notfound
            lea  esi, [eax - 1]         ; number -> 0-based index
            jmp  .found
.by_name:
            xor  esi, esi
.scan:
            call name_contains          ; CF=1 if the typed text is inside this name
            jc   .found                 ; early exit on the first match
            inc  esi
            cmp  esi, [product_count]
            jb   .scan
.notfound:
            PRINT s_notfound
            jmp  .done
.found:
            PRINT s_found
            call print_product_row
.done:
            popad
            ret

; ESI = product index, needle = input_buf. CF=1 if needle occurs in the name
; (case-insensitive substring test: a nested loop over start offsets).
name_contains:
            pushad
            imul ebx, esi, MAX_NAME_LEN
            add  ebx, product_names     ; EBX = where this attempt starts in the name
.attempt:
            mov  esi, input_buf         ; ESI walks the needle
            mov  edi, ebx               ; EDI walks the name
.compare:
            mov  al, [esi]
            test al, al
            jz   .match                 ; whole needle matched
            call to_lower
            mov  ah, al                 ; AH = lower-cased needle char
            mov  al, [edi]
            call to_lower
            cmp  al, ah
            jne  .advance               ; mismatch: try the next start position
            inc  esi
            inc  edi
            jmp  .compare
.advance:
            inc  ebx
            cmp  byte [ebx], 0
            jne  .attempt               ; more name left to try
            clc                         ; ran out of name: no match
            jmp  .out
.match:
            stc
.out:
            popad                       ; POPAD leaves the flags (CF) untouched
            ret

; AL = character -> lower-case if it is 'A'..'Z' (only AL and flags change)
to_lower:
            cmp  al, 'A'
            jb   .done
            cmp  al, 'Z'
            ja   .done
            add  al, 32                 ; 'A' + 32 = 'a'
.done:
            ret

; ============================================================================
; MENU OPTION 4 - Process a sale
; ============================================================================
process_sale:
            pushad
            cmp  dword [product_count], 0
            jne  .start
            PRINT s_none
            jmp  .out
.start:
            mov  dword [cart_count], 0
            mov  dword [order_total], 0
            call view_catalogue

; ---- loop: add items until the user types 0 or the cart is full -------------
.add_loop:
            cmp  dword [cart_count], MAX_CART_ITEMS
            jb   .ask_item
            PRINT s_cart_full
            jmp  .checkout
.ask_item:
            PRINT s_ask_item
            call read_number
            jc   .bad_item
            test eax, eax
            jz   .finish                ; 0 = no more items
            cmp  eax, [product_count]
            ja   .bad_item
            dec  eax
            mov  ebx, eax               ; EBX = product index for this line
.ask_qty:
            PRINT s_ask_qty
            call read_number
            jc   .bad_qty
            test eax, eax
            jz   .add_loop              ; 0 = drop this line, pick again
            mov  edx, eax               ; EDX = requested quantity

            ; available = stock - units of this product already in the cart
            mov  eax, [product_stock + ebx*4]
            xor  ecx, ecx
.reserve:
            cmp  ecx, [cart_count]
            jae  .reserved
            cmp  [cart_idx + ecx*4], ebx
            jne  .next_line
            sub  eax, [cart_qty + ecx*4]
.next_line:
            inc  ecx
            jmp  .reserve
.reserved:
            cmp  edx, eax               ; asked for more than is available?
            ja   .no_stock

            ; line total = price * quantity by REPEATED ADDITION
            mov  ecx, edx               ; ECX = quantity = loop counter (>= 1)
            xor  eax, eax
            mov  esi, [product_prices + ebx*4]
.mul_loop:
            add  eax, esi               ; add the unit price once per unit
            loop .mul_loop

            mov  edi, [cart_count]      ; append the line to the cart
            mov  [cart_idx   + edi*4], ebx
            mov  [cart_qty   + edi*4], edx
            mov  [cart_total + edi*4], eax
            add  [order_total], eax     ; running order total
            inc  dword [cart_count]
            PRINT s_line_add
            call print_money            ; EAX still holds the line total
            PRINT s_nl
            jmp  .add_loop

.bad_item:
            PRINT s_bad_item
            jmp  .ask_item
.bad_qty:
            PRINT s_bad_qty
            jmp  .ask_qty
.no_stock:
            PRINT s_no_stock
            call print_num              ; EAX = units still available
            PRINT s_nl
            jmp  .ask_qty               ; re-ask the quantity for the same line

.finish:
            cmp  dword [cart_count], 0
            jne  .checkout
            PRINT s_cancel              ; nothing was added
            jmp  .out

; ---- checkout: discount, payment, stock update, receipt ---------------------
.checkout:
            PRINT s_nl
            PRINT s_subtotal
            mov  eax, [order_total]
            call print_money
            PRINT s_nl
            call apply_discount
            cmp  dword [discount_amt], 0
            je   .show_total
            PRINT s_discount
            mov  eax, [discount_amt]
            call print_money
            PRINT s_nl
.show_total:
            PRINT s_total_due
            mov  eax, [order_total]
            call print_money
            PRINT s_nl
.ask_cash:
            PRINT s_ask_cash
            call read_number
            jc   .bad_cash
            test eax, eax
            jz   .cancel_sale
            cmp  eax, [order_total]
            jb   .short_cash            ; insufficient payment: ask again
            mov  [cash_tendered], eax
            sub  eax, [order_total]     ; change = cash - total
            mov  [change_due], eax
            call update_stock
            call print_receipt
            inc  dword [txn_count]
            mov  eax, [order_total]
            add  [total_revenue], eax   ; session revenue accumulator
            jmp  .out
.bad_cash:
            PRINT s_bad_num
            jmp  .ask_cash
.short_cash:
            PRINT s_short
            jmp  .ask_cash
.cancel_sale:
            PRINT s_cancel
.out:
            popad
            ret

; Discount by REPEATED SUBTRACTION: every full DISCOUNT_BLOCK of spend removes
; DISCOUNT_BLOCK from a working copy and earns DISCOUNT_PER_BLOCK off (10%).
apply_discount:
            pushad
            mov  dword [discount_amt], 0
            mov  eax, [order_total]
            cmp  eax, DISCOUNT_THRESHOLD
            jb   .done                  ; below the threshold: no discount
            xor  edx, edx               ; EDX = discount earned so far
.block:
            cmp  eax, DISCOUNT_BLOCK
            jb   .apply                 ; less than one full block left
            sub  eax, DISCOUNT_BLOCK
            add  edx, DISCOUNT_PER_BLOCK
            jmp  .block
.apply:
            mov  [discount_amt], edx
            sub  [order_total], edx     ; amount due after discount
.done:
            popad
            ret

; Deduct every cart line from stock and remember which lines hit low stock.
update_stock:
            pushad
            xor  ecx, ecx               ; ECX = cart line
.line:
            cmp  ecx, [cart_count]
            jae  .done
            mov  esi, [cart_idx + ecx*4]
            mov  eax, [product_stock + esi*4]
            sub  eax, [cart_qty + ecx*4]
            mov  [product_stock + esi*4], eax
            mov  dword [cart_low + ecx*4], 0
            cmp  eax, LOW_STOCK_LEVEL
            ja   .next                  ; plenty left
            mov  dword [cart_low + ecx*4], 1
.next:
            inc  ecx
            jmp  .line
.done:
            popad
            ret

; Itemised receipt (loops over the cart).
print_receipt:
            pushad
            PRINT s_rcpt_head
            xor  ecx, ecx               ; ECX = cart line
.line:
            cmp  ecx, [cart_count]
            jae  .footer
            mov  eax, [cart_qty + ecx*4]
            call print_num
            PRINT s_times
            imul esi, [cart_idx + ecx*4], MAX_NAME_LEN
            add  esi, product_names
            call print_name
            PRINT s_sp2
            mov  eax, [cart_total + ecx*4]
            call print_money
            cmp  dword [cart_low + ecx*4], 0
            je   .no_low
            PRINT s_low
.no_low:
            PRINT s_nl
            inc  ecx
            jmp  .line
.footer:
            PRINT s_rcpt_line
            PRINT s_subtotal
            mov  eax, [order_total]
            add  eax, [discount_amt]    ; subtotal = total due + discount
            call print_money
            PRINT s_nl
            cmp  dword [discount_amt], 0
            je   .totals
            PRINT s_discount
            mov  eax, [discount_amt]
            call print_money
            PRINT s_nl
.totals:
            PRINT s_total_due
            mov  eax, [order_total]
            call print_money
            PRINT s_nl
            PRINT s_cash
            mov  eax, [cash_tendered]
            call print_money
            PRINT s_nl
            PRINT s_change
            mov  eax, [change_due]
            call print_money
            PRINT s_nl
            PRINT s_rcpt_line
            PRINT s_thanks
            popad
            ret

; ============================================================================
; MENU OPTION 5 - Restock product
; ============================================================================
restock_product:
            pushad
            cmp  dword [product_count], 0
            jne  .show
            PRINT s_none
            jmp  .out
.show:
            call view_catalogue
.ask_prod:
            PRINT s_ask_rs
            call read_number
            jc   .bad_prod
            test eax, eax
            jz   .out                   ; 0 = cancel
            cmp  eax, [product_count]
            ja   .bad_prod
            dec  eax
            mov  ebx, eax               ; EBX = product index
.ask_units:
            PRINT s_ask_units
            call read_number
            jc   .bad_units
            mov  ecx, [product_stock + ebx*4]
            add  ecx, eax               ; new stock = old + units
            cmp  ecx, MAX_STOCK
            ja   .too_many              ; would overflow the stock limit
            mov  [product_stock + ebx*4], ecx
            PRINT s_restocked
            jmp  .out
.bad_prod:
            PRINT s_bad_item
            jmp  .ask_prod
.bad_units:
            PRINT s_bad_num
            jmp  .ask_units
.too_many:
            PRINT s_too_many
            jmp  .ask_units
.out:
            popad
            ret

; ============================================================================
; MENU OPTION 6 - Sales report
; ============================================================================
sales_report:
            pushad
            PRINT s_rep_head
            PRINT s_rep_txn
            mov  eax, [txn_count]
            call print_num
            PRINT s_nl
            PRINT s_rep_rev
            mov  eax, [total_revenue]
            call print_money
            PRINT s_nl
            popad
            ret

; ============================================================================
; I/O AND CONVERSION HELPERS
; ============================================================================

; ECX = address, EDX = length  ->  sys_write to the screen
print_str:
            pushad
            mov  eax, SYS_WRITE
            mov  ebx, STDOUT
            int  0x80                   ; ECX/EDX are already the buffer/length
            popad
            ret

; ESI = address of a MAX_NAME_LEN-byte name slot -> prints it padded with spaces
print_name:
            pushad
            mov  edi, name_tmp
            mov  ecx, MAX_NAME_LEN
.copy:
            lodsb
            test al, al
            jnz  .keep
            mov  al, ' '                ; NUL padding becomes visible spaces
.keep:
            stosb
            loop .copy
            mov  ecx, name_tmp
            mov  edx, MAX_NAME_LEN
            call print_str
            popad
            ret

; EAX = unsigned number -> prints it in decimal (repeated DIV by 10)
print_num:
            pushad
            mov  edi, num_buf + NUM_BUF_LEN ; fill the buffer from the right
            mov  ebx, 10
.digit:
            xor  edx, edx
            div  ebx                    ; EAX = quotient, EDX = remainder (next digit)
            add  dl, '0'                ; digit -> ASCII
            dec  edi
            mov  [edi], dl
            test eax, eax
            jnz  .digit                 ; until nothing is left to divide
            mov  ecx, edi
            mov  edx, num_buf + NUM_BUF_LEN
            sub  edx, edi               ; length = end - start
            call print_str
            popad
            ret

; EAX = cents -> prints "RM x.xx"
print_money:
            pushad
            PRINT s_rm
            xor  edx, edx
            mov  ebx, 100
            div  ebx                    ; EAX = ringgit, EDX = sen
            mov  esi, edx               ; keep the sen (PRINT/print_num preserve ESI)
            call print_num
            PRINT s_dot
            mov  eax, esi
            cmp  eax, 10
            jae  .two_digits
            PRINT s_zero                ; 5 sen must print as .05
.two_digits:
            call print_num
            popad
            ret

; Reads one line from the keyboard into input_buf (NUL-terminated, no newline).
; Reads a byte at a time so it also works with piped input; extra characters
; beyond INPUT_MAX are read and thrown away so they cannot leak into the next
; prompt. End-of-input exits the program instead of looping forever.
read_line:
            pushad
            xor  esi, esi               ; ESI = characters stored so far
.next_char:
            mov  eax, SYS_READ
            mov  ebx, STDIN
            mov  ecx, char_buf
            mov  edx, 1
            int  0x80
            cmp  eax, 1
            jne  quit                   ; EOF or error
            mov  al, [char_buf]
            cmp  al, 10
            je   .done                  ; newline ends the line
            cmp  al, 13
            je   .next_char             ; ignore CR
            cmp  esi, INPUT_MAX
            jae  .next_char             ; buffer full: discard the excess
            mov  [input_buf + esi], al
            inc  esi
            jmp  .next_char
.done:
            mov  byte [input_buf + esi], 0
            popad
            ret

; Parses input_buf as an unsigned decimal number.
; Returns EAX = value and CF=0, or CF=1 if empty / not all digits / > 9 digits.
atoi:
            pushad
            mov  esi, input_buf
            xor  eax, eax               ; EAX = value so far
            xor  ecx, ecx               ; ECX = digits seen
.next:
            movzx edx, byte [esi]
            test edx, edx
            jz   .end                   ; NUL: finished
            sub  edx, '0'
            cmp  edx, 9
            ja   .bad                   ; unsigned test also rejects chars below '0'
            lea  eax, [eax + eax*4]     ; value * 5
            add  eax, eax               ; ... * 2 = value * 10 (ADD, no MUL needed)
            add  eax, edx               ; add the new digit
            inc  ecx
            cmp  ecx, 9
            ja   .bad                   ; > 9 digits could overflow 32 bits
            inc  esi
            jmp  .next
.end:
            test ecx, ecx
            jz   .bad                   ; empty line
            mov  [esp + 28], eax        ; overwrite the saved EAX so POPAD returns it
            clc
            popad
            ret
.bad:
            stc
            popad
            ret

; read_line + atoi: EAX = number, CF=1 on invalid input
read_number:
            call read_line
            call atoi
            ret
