# SmartMart – Detailed Code Analysis

For every block of `smart-mart.asm` this document answers three questions:

1. **Purpose** – what is this block for?
2. **How it works** – the mechanism, in plain words.
3. **If it were missing / wrong** – what would break, and how badly?

Line numbers like `(L207)` refer to `smart-mart.asm`.

**Severity tags** used in the "if missing" parts:
- 💥 **Crash / hang** – program dies or never finishes.
- ❌ **Wrong result** – runs, but gives incorrect data or money.
- 🎨 **Cosmetic** – works, but looks wrong or is harder to maintain.
- ✅ **Safe / defensive** – removing it would probably still work; it's there for safety or clarity.

> **Note:** the "if missing" effects are **reasoned from reading the code** (what the CPU would do), not from running experiments. They are accurate enough for an interview, but if you want to be 100% sure about one, you can delete the line, rebuild, and watch.

---

## 0. The big picture (data flow)

```
                         ┌──────────────┐
   keyboard ──read_line──► input_buf    │  (text, NUL-terminated)
                         └──────┬───────┘
                              atoi
                                ▼
                    EAX = number (CF=1 if invalid)
                                ▼
   main_loop ── jump table ──► one of 7 menu routines
                                │
        ┌───────────────┬───────┴────────┬─────────────────┐
   add_product     process_sale      restock         view/search/report
        │               │                │                  │
        └─────── product_names / product_prices / product_stock arrays ───────┐
                        │ (cart_* arrays, order_total, ...)                    │
                        ▼                                                      │
        print_num / print_money / print_name / print_str ──► sys_write ──► screen
```

Three layers:
- **Layer 1 – I/O helpers:** `print_str`, `print_num`, `print_money`, `print_name`, `read_line`, `atoi`, `read_number`.
- **Layer 2 – business routines:** one per menu option plus helpers (`apply_discount`, `update_stock`, `print_receipt`, ...).
- **Layer 3 – the main loop/dispatcher** that ties them together.

---

## 1. Header comment & constants (L1–40)

### 1.1 Header comment (L1–21)
- **Purpose:** documents the platform, build command, money convention and the register convention.
- **If missing:** ✅ no effect on the program. It's documentation, but a marker/reader would lose the design explanation (cents, `PUSHAD`/`POPAD`, `CF` as return flag).

### 1.2 System-call constants (L24–28)
```
SYS_EXIT EQU 1   SYS_READ EQU 3   SYS_WRITE EQU 4   STDIN EQU 0   STDOUT EQU 1
```
- **Purpose:** give names to the Linux syscall numbers and file descriptors.
- **How:** `EQU` is a pure assembler substitution – no memory used.
- **If missing:** the assembler reports "undefined symbol" at every use. If you replaced each with a raw number it would still work, but 🎨 `mov eax, 4` is unreadable compared to `mov eax, SYS_WRITE`.

### 1.3 Limit constants (L30–40)

| Constant | Value | Purpose | If it were wrong or missing |
|---|---|---|---|
| `MAX_PRODUCTS` | 10 | catalogue capacity; sizes the arrays | ❌/💥 If code allowed more than the arrays hold, new products overwrite neighbouring data (see §2.1) |
| `MAX_NAME_LEN` | 16 | bytes per name slot (15 chars + NUL) | ❌ Wrong value breaks every `index × 16` address calculation → wrong names printed |
| `MAX_CART_ITEMS` | 5 | lines per sale; sizes cart arrays | 💥 Larger than array size → cart writes spill into the next array (corrupts quantities/totals) |
| `MAX_PRICE` | 99999 | max price in cents | ❌ Without a cap, large prices × quantity can exceed 2³² and wrap around → wrong totals |
| `MAX_STOCK` | 999 | max units per product | ❌ Without it, restock could push stock to absurd values; also keeps numbers short |
| `DISCOUNT_THRESHOLD` | 5000 | min order (RM 50) for a discount | ❌ Wrong value changes who gets a discount (business rule) |
| `DISCOUNT_BLOCK` | 500 | every RM 5.00 of spend... | ❌ Changes discount size |
| `DISCOUNT_PER_BLOCK` | 50 | ...earns RM 0.50 off | ❌ Changes discount size |
| `LOW_STOCK_LEVEL` | 3 | stock ≤ this is flagged | 🎨 Changes when `[LOW STOCK]` appears |
| `INPUT_MAX` | 63 | chars kept from one line | 💥 If larger than `input_buf` size, long input overflows the buffer into `char_buf`/other data |
| `NUM_BUF_LEN` | 12 | digit buffer for `print_num` | 💥/❌ A 32-bit number has up to 10 digits; a buffer smaller than that overflows backwards |

**Why constants instead of literal numbers?** Change a rule in **one** place (e.g. `MAX_PRODUCTS`) and the arrays, the checks and the loops all follow. Without constants the same number would be scattered through the file and easy to miss. 🎨

---

## 2. Macros (L42–64)

### 2.1 `STR` (L44–47)
```
%macro STR 2+
%1:       db %2
%1_len    equ $ - %1
%endmacro
```
- **Purpose:** define a message **and** its length in one line.
- **How:** `$` is the current address, so `$ - label` = bytes since the label = string length. `2+` lets the text contain commas (`"abc", 10`).
- **If missing:** every message would need `db` plus a hand-counted length (`mov edx, 14`). ❌ One miscount = cut-off text or garbage printed after it. Also ~60 lines of repetition.

### 2.2 `NAME` (L50–53)
```
%%start:  db %1
          times MAX_NAME_LEN - ($ - %%start) db 0
```
- **Purpose:** make each seeded product name occupy **exactly 16 bytes** (text + zero padding).
- **How:** `%%start` marks where the text began; `$ - %%start` is its length; pad with zeros to 16.
- **If missing:** names would be different lengths, so `names + index*16` would point into the middle of names → ❌ wrong/garbled product names everywhere. The zero padding is also what provides the NUL terminator that `print_name`, `name_contains` rely on.

### 2.3 `PRINT` (L56–64)
- **Purpose:** one-line "print this message" that **doesn't disturb ECX/EDX**.
- **How:** push ECX/EDX, load address + length, `call print_str`, pop ECX/EDX.
- **If missing:** you'd write 3–4 lines at ~100 places 🎨. **If the push/pop were dropped:** ❌ ECX/EDX would be overwritten – e.g. `print_receipt` keeps its cart-line counter in ECX across many `PRINT`s, so the counter would be trashed and the receipt loop would print wrong or endless lines.

---

## 3. `.data` section (L66–168)

### 3.1 Product arrays (L70–82)
```
product_names:  4 names + (MAX_PRODUCTS-4)*16 zero bytes
product_prices: dd 500,200,150,350 + zeros
product_stock:  dd 10,20,5,4 + zeros
product_count:  dd 4
```
- **Purpose:** the "database": **parallel arrays** (same index = same product) pre-seeded with 4 demo products.
- **How:** they sit one after another in memory.
- **If the `times ... db 0` padding were missing:** 💥/❌ the arrays would only be 4 entries long. Adding product #5 would write **past the end of `product_names` into `product_prices`**, corrupting the first prices. The padding reserves the full 10 slots.
- **If `product_count` were missing:** ❌ the program wouldn't know how many products exist – loops, search bounds and "next free slot" all depend on it.
- **If the seed data were removed:** ✅ works, but the shop starts empty ("No products in the catalogue yet") – the demo needs the user to add products first.

### 3.2 `menu_table` (L85–86)
- **Purpose:** array of 7 routine addresses; lets the main loop dispatch with one `call`.
- **If missing / wrong order:** 💥/❌ without it the dispatch line has nothing to read; with the wrong order, option 3 would run the wrong routine. The alternative is a chain of 7 `cmp/je` pairs (works but longer).

### 3.3 Screen text (L89–168)
- **Purpose:** all text shown to the user: banner, menu, prompts, errors, labels.
- **If one is missing:** the assembler errors on the `PRINT label` that refers to it.
- **`s_banner_len` / `s_menu_len` defined manually with `equ $ - ...`** because they are multi-line `db` blocks that don't use `STR`.
- **Content such as `10`** = newline character; without it text would run together on one line 🎨.

---

## 4. `.bss` section (L170–187)

`.bss` = reserved, zero-filled memory that costs nothing in the executable file.

| Variable | Purpose | If missing |
|---|---|---|
| `cart_idx`, `cart_qty`, `cart_total`, `cart_low` (5 × 4 bytes each) | The shopping cart: which product, how many, line total, low-stock flag | ❌ Nowhere to remember the sale until checkout, so no multi-item sale, no receipt |
| `cart_count` | Number of lines in the cart | ❌ Loops over the cart wouldn't know where to stop |
| `order_total` | Amount due | ❌ No total; no change calculation |
| `discount_amt` | Discount in cents (kept so the receipt can show it) | ❌ Receipt can't show the discount line or work out the subtotal |
| `cash_tendered`, `change_due` | Needed by the receipt after the sale routine computed them | ❌ Receipt can't print cash/change |
| `txn_count`, `total_revenue` | Session totals for the report | ❌ Sales report would have nothing to show |
| `input_buf` (64 bytes) | One typed line, NUL-terminated | ❌ Nowhere to store the user's text |
| `char_buf` (1 byte) | Receives each byte from `sys_read` | ❌ `sys_read` needs a buffer address |
| `name_tmp` (16 bytes) | Padded copy of a name for printing | ❌ `print_name` has nowhere to build the spaces-for-NUL copy |
| `num_buf` (12 bytes) | Where `print_num` builds its digits | ❌ Numbers couldn't be converted to text |

**Why `.bss` instead of `.data` for these?** They have no useful initial value. The file stays smaller, and the OS gives zeroed memory (which is why `txn_count` and `total_revenue` correctly start at 0).

**Subtle point:** because `.bss` is zero **only at program start**, `process_sale` must reset `cart_count` and `order_total` itself at the beginning of every sale (see §8).

---

## 5. Entry point and main loop (L190–217)

### 5.1 `section .text` and `global _start` (L190–191)
- **Purpose:** marks the code section, and exports `_start` – where the Linux loader begins execution.
- **If `global _start` were missing:** 💥 `ld` warns "cannot find entry symbol _start" and the program won't start properly.

### 5.2 `cld` (L196)
- **Purpose:** clear the direction flag so `lodsb`/`stosb` move **forward**.
- **If missing:** ✅ on Linux the flag is already clear at program start, so it would most likely still work. It's a defensive habit. If the flag were set, strings would be copied **backwards** → ❌ garbled names.

### 5.3 Banner (L197) and menu loop (L198–211)
```
main_loop:
    PRINT menu / PRINT prompt
    call read_number
    jc  .invalid
    cmp eax,1 / jb .invalid
    cmp eax,7 / ja .invalid
    call [menu_table + eax*4 - 4]
    jmp main_loop
.invalid: PRINT s_bad_choice / jmp main_loop
```

| Line(s) | Purpose | If missing |
|---|---|---|
| `call read_number` | Get the user's choice | ❌ No input → nothing to dispatch on |
| `jc .invalid` | Reject non-numbers ("abc") | ❌ On bad input `atoi` leaves EAX as a stale old value, so typing "abc" would silently run some random menu option |
| `cmp eax,1 / jb` | Reject 0 | 💥 `eax=0` → table offset −4 → reads the 4 bytes **before** the table → jumps to a garbage address → crash |
| `cmp eax,7 / ja` | Reject 8+ | 💥 reads past the table (into the screen text bytes) → jumps into the data → crash |
| `call [menu_table + eax*4 - 4]` | Jump to the routine for that option | ❌ Menu does nothing |
| `jmp main_loop` | Show the menu again after each action | ❌ **Falls through into `.invalid`** → prints "Invalid choice" after every action (then jumps back, so it "works" but is wrong). Without `.invalid`'s own `jmp` the program would run into `quit` |
| `.invalid` block | Print an error then return to the menu | ❌ Invalid input would have nowhere to go |

**Why `call` and not `jmp` for dispatch?** Each routine ends with `ret`, which returns to the instruction after the `call` – i.e. to `jmp main_loop`. That's how control comes back to the menu.

### 5.4 `quit` (L213–217)
- **Purpose:** print "Goodbye!" and call `sys_exit(0)`.
- **How:** `eax=1`, `ebx=0`, `int 0x80`.
- **If missing the exit syscall:** 💥 the CPU keeps executing whatever bytes follow (the next routine `add_product`), eventually crashing (e.g. segmentation fault on a bad `ret`). A program in assembly **must** exit explicitly; there's no "end of main" that does it for you.
- **`xor ebx, ebx`** sets the exit code to 0 = success. ✅ If omitted, EBX would hold some leftover value → a random exit status.

---

## 6. Add product (L222–276)

**Purpose of the whole routine:** append a new product (name, price, stock) to the three parallel arrays after validating everything.

| Block | Purpose | If missing |
|---|---|---|
| `pushad` / `popad` / `ret` | Preserve caller's registers, return | 💥 Without the matching `popad` the stack is unbalanced and `ret` jumps to a wrong address → crash. Without both: ❌ caller's EBX/ESI/etc. destroyed |
| `cmp [product_count], MAX_PRODUCTS / jb .room` | Capacity check | 💥/❌ An 11th product would write past the arrays, corrupting `product_count` or other data |
| `.ask_name` + `cmp byte [input_buf],0 / je .ask_name` | Reject empty name | ❌ A product with a blank name (all NUL) would be created; it would display as spaces and could never be found by name |
| `imul edi,[product_count],MAX_NAME_LEN` + `add edi, product_names` | Compute address of next free slot = base + count × 16 | ❌ Without it EDI is undefined → name written to a random location (💥 likely crash) |
| `mov esi, input_buf` / `mov ecx, MAX_NAME_LEN-1` | Source pointer and **max 15 chars** | 💥/❌ With no limit a long name overflows into the **next product's slot** |
| `.copy: lodsb / test al,al / jz / stosb / loop` | Copy text up to its NUL; stop at 15 | ❌ Name not stored. The `test/jz` stops at the end of short names; `loop` stops at 15 for long ones |
| Why 15, not 16? | Last byte must stay 0 (slot is pre-zeroed) = the NUL terminator | ❌ A 16-char name would have **no terminator**; `name_contains` would run on into the next name and could match across two products |
| `.ask_price`: `jc` / `cmp 1` / `cmp MAX_PRICE` | Valid number between 1 and 99999 | ❌ Price 0 = free item; huge price = total overflow |
| `mov ebx, eax` | Keep the validated price while later prompts run | ❌ EAX is overwritten by the next `read_number`, the price would be lost. (EBX is safe because every routine preserves it with `pushad`) |
| `.ask_stock`: `jc` / `cmp MAX_STOCK` | Valid stock 0–999 | ❌ Stock could be absurd; also breaks the invariant that restock checks assume |
| `mov esi,[product_count]` + two `mov [..+esi*4]` | Store price and stock at the new index | ❌ Product has a name but no price/stock → sells for 0 |
| `inc dword [product_count]` | Make the product "official" | ❌ **Last step is crucial**: without it the new product is stored but invisible to listing, search and sale |
| Error branches (`.bad_price`, `.bad_stock`) | Print error and re-ask | ❌ Invalid input would be accepted or the program would continue with garbage |

**Design note:** the count is incremented **last** so a half-finished add can never leave a product with missing fields visible.

---

## 7. View catalogue and product row (L281–322)

### 7.1 `view_catalogue` (L281–297)
- **Purpose:** list every product.
- **How:** `ESI = 0`; loop: print row, `inc esi`, `cmp esi,[product_count]`, `jb .row`.
- **If the empty check (`cmp ... 0 / jne .have`) were missing:** ❌ the loop is **do-while** (test at the bottom), so with 0 products it would still print one garbage row (an empty product at index 0).
- **If `inc esi` were missing:** 💥 infinite loop printing row 1 forever.
- **If the `jb .row` were missing:** ❌ only the first product ever listed.

### 7.2 `print_product_row` (L300–322)
- **Purpose:** print `N. name  RM x.xx  Stock: n` for the product index in ESI. Shared by catalogue, search, and the sale screen (reuse = less code).
- **How:** `mov ebx, esi` (ESI gets reused as a pointer), `inc eax` (humans count from 1), pad single digits, `print_num`, `imul esi, ebx, 16` + `add esi, product_names` → pointer to the name, `print_name`, load price/stock from `[array + ebx*4]`.
- **If `inc eax` were missing:** ❌ numbering would start at 0, but the menu/sale asks for numbers starting at 1 → the user picks the wrong product (off-by-one).
- **If the `cmp eax,10 / jae .wide` padding were missing:** 🎨 columns misalign from item 10 onward.
- **If `mov ebx, esi` were missing:** ❌ ESI is overwritten with the name pointer; subsequent `[product_prices + ebx*4]` would use a wrong index.

---

## 8. Search (L327–406)

### 8.1 `search_product` (L327–362)
- **Purpose:** find a product by **number** or by **part of its name**.
- **How:** read a line → try `atoi`. All digits → treat as product number; otherwise (`jc .by_name`) → scan names.

| Line(s) | Purpose | If missing |
|---|---|---|
| empty-catalogue check | Say "no products" | ❌ would try to search nothing / show garbage |
| `cmp byte [input_buf],0 / je .done` | Empty input = go back | ❌ empty needle would match everything (or `atoi` fails) |
| `call atoi / jc .by_name` | Decide number vs name | ❌ Name search is impossible (everything treated as number) |
| `cmp eax,1 / jb`; `cmp eax,[count] / ja` | Number range check | ❌ Out-of-range index reads **outside the arrays** → garbage product shown |
| `lea esi,[eax-1]` | Convert 1-based number to 0-based index | ❌ off-by-one: shows the wrong product. (`lea` is used as a calculator; it doesn't change flags.) |
| `.scan` loop with `jc .found` | Test each product; stop at the first match | ❌ Without the early exit, it would keep going and report the last item |
| `.notfound` | Message when nothing matched | ❌ silent failure; user doesn't know the search ended |

### 8.2 `name_contains` (L366–396)
- **Purpose:** is the typed text found **anywhere inside** this product's name? (case-insensitive)
- **How (nested loop):**
  - `EBX` = where this attempt starts in the name; `ESI` = walks the needle; `EDI` = walks the name.
  - Compare char by char. Reaching the needle's end (NUL) means **all matched** → `stc`.
  - A mismatch → `inc ebx` (slide start one char) and try again, until the name's NUL is reached → `clc`.
- **If the "slide" (`.advance`) part were missing:** ❌ it would only match names that **start with** the text ("ote" wouldn't find "Notebook").
- **If `to_lower` calls were missing:** ❌ "pen" would not find "Pen".
- **`stc`/`clc` and `popad`:** the answer is returned in CF. `popad` doesn't change flags, so CF survives. If `popad` did alter flags, the result would be lost. (**Honest note:** `clc` at `.advance` is technically redundant, since the earlier `cmp byte [ebx],0` equal → CF is already 0. It's kept for clarity. ✅)
- **If `pushad`/`popad` were missing:** ❌ ESI/EDI/EBX would be changed, and `search_product`'s loop counter `ESI` would be wrecked.
- **Why `AL` and `AH`?** `to_lower` only works on AL. The needle's char is lowered first, saved to AH, then the name's char is lowered into AL, then compared.

### 8.3 `to_lower` (L399–406)
- **Purpose:** turn `'A'–'Z'` into `'a'–'z'` (add 32).
- **If the range checks (`'A'`/`'Z'`) were missing:** ❌ **every** character would get +32: digits, spaces and punctuation become different characters, and lowercase letters (97+32=129) become garbage → almost nothing would match.

---

## 9. Process sale (L411–545)

The biggest routine. Steps: start → add lines → checkout → payment → update stock → receipt.

### 9.1 Start (L412–420)
- Empty-catalogue check: can't sell nothing. ❌ without it an empty list is shown and selection is meaningless.
- `mov dword [cart_count], 0` / `[order_total], 0`: ❌ **without the reset the second sale would still contain the previous sale's items and total** (`.bss` is only zero at program start).
- `call view_catalogue`: shows the user what's available. 🎨 without it they'd have to remember the numbers.

### 9.2 Add-item loop (L423–491)

| Block | Purpose | If missing |
|---|---|---|
| `cmp [cart_count], MAX_CART_ITEMS / jb .ask_item` | Stop at 5 lines → go to checkout | 💥/❌ A 6th line writes past each cart array into the next one (e.g. `cart_idx[5]` = `cart_qty[0]`) → corrupted quantities |
| `call read_number / jc .bad_item` | Item number must be a number | ❌ Letters accepted with a stale EAX |
| `test eax,eax / jz .finish` | `0` = "no more items" | ❌ The user has no way to finish; they'd only reach checkout by filling 5 lines |
| `cmp eax,[product_count] / ja .bad_item` | Number must exist | ❌ Reading beyond the arrays → garbage product |
| `dec eax` / `mov ebx, eax` | Number → index; keep it in EBX | ❌ Off-by-one: sells the **wrong product**. Losing EBX loses the product for the rest of the line |
| `test eax,eax / jz .add_loop` after qty | `0` = drop the line | 💥 **A quantity of 0 would reach `loop` with ECX=0**: `loop` decrements to −1 and runs ~4 billion times (hang/garbage total) |
| `mov edx, eax` | Keep quantity (EAX is reused) | ❌ quantity lost |

### 9.3 Stock reservation loop (L446–460)
```
available = stock − (quantity of this same product already in the cart)
if requested > available → "Not enough stock"
```
- **Purpose:** the stock array isn't reduced until payment, so the cart itself must be checked, otherwise the user could add "Notebook ×8" twice with only 10 in stock.
- **If missing:** ❌ **overselling**: later `update_stock` would subtract more than exists, and since the numbers are unsigned, the stock becomes ≈ 4 billion instead of negative.
- **If `ja .no_stock` were missing:** ❌ same overselling.
- **`.no_stock` prints EAX (units left) then jumps back to `.ask_qty`**, so the user can retry the same product.

### 9.4 Line total by repeated addition (L463–468)
```
mov ecx, edx ; xor eax,eax ; mov esi,price
.mul_loop: add eax, esi ; loop .mul_loop
```
- **Purpose:** price × quantity **without `mul`** (the project's "arithmetic using ADD" requirement).
- **If `xor eax, eax` were missing:** ❌ the sum starts from leftover junk (the stock number just calculated) → wrong total.
- **If `mov ecx, edx` were missing:** 💥/❌ ECX is arbitrary (it was the cart-scan counter) → wrong number of additions.

### 9.5 Add to the cart (L470–479)
- Store index, quantity, total at position `cart_count`; `add [order_total], eax`; `inc [cart_count]`; print the line total.
- **If `inc [cart_count]` were missing:** ❌ every new line overwrites the previous one; the cart never grows.
- **If `add [order_total], eax` were missing:** ❌ total always 0 → everything free.

### 9.6 Finish / cancel (L493–497)
- If the user ends with an empty cart → "Sale cancelled". ❌ Without it, checkout would run with a RM 0.00 total and issue an empty receipt (and count it as a transaction).

### 9.7 Checkout (L500–540)

| Block | Purpose | If missing |
|---|---|---|
| Print subtotal | User sees amount before discount | 🎨 |
| `call apply_discount` | Compute discount, reduce `order_total` | ❌ No discount ever (business rule lost) |
| `cmp [discount_amt],0 / je .show_total` | Only print the discount line if there is one | 🎨 prints "Discount: -RM 0.00" on every sale |
| `.ask_cash`: `jc .bad_cash` | Cash must be a number | ❌ garbage cash |
| `test eax,eax / jz .cancel_sale` | `0` = cancel | 🎨 no way out of a stuck payment (user can't cancel) |
| `cmp eax,[order_total] / jb .short_cash` | Reject underpayment | ❌ **Customer pays less than the total; change = cash − total wraps to ≈ 4 billion** (unsigned) – huge bogus change |
| `mov [cash_tendered], eax` / `sub eax,[order_total]` / `mov [change_due], eax` | Compute change = cash − total (SUB) and store | ❌ receipt can't show cash/change |
| `call update_stock` | Deduct stock **only now**, after payment | ❌ If done earlier, a cancelled sale would still lose stock. If missing, stock never goes down → infinite sales |
| `call print_receipt` | Show receipt | ❌ no proof of purchase (logic still OK) |
| `inc [txn_count]` / `add [total_revenue], eax` | Session totals | ❌ report always shows 0 |
| `.cancel_sale` → prints "Sale cancelled" | Nothing was changed | ❌ Without it a cancelled sale gives no feedback |

**Key design point:** nothing permanent happens (stock, counters) until payment succeeds, so cancel at any point leaves the system unchanged.

### 9.8 `apply_discount` (L549–567) – repeated subtraction
```
discount = 0
if total < 5000: done
eax = total; edx = 0
while eax >= 500: eax -= 500; edx += 50
discount_amt = edx; order_total -= edx
```
- **Purpose:** RM 0.50 off per full RM 5.00 when the order is at least RM 50 – no `div` or `mul`.
- **If `mov [discount_amt],0` at the top were missing:** ❌ a previous sale's discount would remain if this sale earns none (since the value is only set when a discount applies).
- **If the threshold check were missing:** ❌ Discount applies to all orders of RM 5.00+ (the rule would change).
- **If `sub [order_total], edx` were missing:** ❌ discount calculated and shown but **never actually deducted** – the customer pays full price.
- **Worked example:** 5700 → 11 blocks (5500) → discount 550 → due 5150. The 200 left over earns nothing.

### 9.9 `update_stock` (L570–589)
- **Purpose:** after payment, subtract each cart line from the product's stock and flag products that reached low stock.
- **If missing:** ❌ stock never decreases.
- **`mov dword [cart_low+ecx*4], 0` then set to 1 only if low:** clears any old flag. ❌ Without the clear, a previous sale's "1" would persist in the same cart slot → false `[LOW STOCK]` warnings.
- **`cmp eax, LOW_STOCK_LEVEL / ja .next`:** unsigned compare: stock 0..3 → flagged.

### 9.10 `print_receipt` (L592–644)
- **Purpose:** the itemised receipt: lines, subtotal, discount, total, cash, change.
- **Subtotal trick:** `order_total + discount_amt` – because `order_total` already had the discount subtracted.
- **If the subtotal used `order_total` alone:** ❌ the subtotal would equal the total due, hiding the discount.
- **If the cart loop's `inc ecx` were missing:** 💥 infinite loop on the first line.
- **If the whole routine were missing:** the sale still completes correctly (✅ business logic unaffected), but the customer gets no receipt.

---

## 10. Restock (L649–689)

- **Purpose:** add units to an existing product.
- **How:** choose product (0 cancels), enter units, `new = old + units` (`mov ecx,[stock]` / `add ecx, eax`).
- **If `cmp ecx, MAX_STOCK / ja .too_many` were missing:** ❌ stock can exceed the limit (breaking the 999 cap used elsewhere).
- **Why compute in ECX and not store immediately?** The new value is checked **before** writing, so a rejected restock leaves stock unchanged.
- **If `jc .bad_units` were missing:** ❌ Letters are accepted with a stale EAX (a random number of units added).
- **If `dec eax` were missing:** ❌ restocks the wrong product (off-by-one).

---

## 11. Sales report (L694–706)

- **Purpose:** display the number of completed sales and total revenue **this session**.
- **How:** loads `txn_count` and `total_revenue`, prints with `print_num` / `print_money`.
- **If missing:** ✅ no effect on the shop's operation, but the manager has no summary. Values only change in `process_sale` after payment → cancelled sales aren't counted (correct).
- **Limitation:** data is kept in memory only; it's lost when the program exits.

---

## 12. I/O and conversion helpers (L708–847)

### 12.1 `print_str` (L713–719)
- **Purpose:** the **only** place that calls `sys_write`; prints `EDX` bytes starting at address `ECX`.
- **How:** `eax=4`, `ebx=1`, `int 0x80`. ECX/EDX are already set by the caller.
- **If missing:** 💥 nothing could be displayed (all output goes through it).
- **If `pushad/popad` were missing:** ❌ the syscall overwrites EAX (it returns the byte count) and EBX is changed → every caller loses those registers. E.g. `add_product` keeps the price in EBX across prompts, which would be destroyed by the next `PRINT`.

### 12.2 `print_name` (L722–738)
- **Purpose:** print a 16-byte name slot with **spaces instead of NUL padding**.
- **How:** copy 16 bytes into `name_tmp`, replacing 0 by `' '`, then print `name_tmp`.
- **If the NUL→space replacement were missing:** 🎨 the terminal would receive raw NUL bytes → columns misaligned (or odd characters).
- **Why copy instead of editing in place?** The product's real name must keep its NUL terminator for `name_contains`; the copy keeps the original safe.

### 12.3 `print_num` (L741–758) – number → text
```
edi = end of num_buf ; ebx = 10
do { edx=0 ; eax/=10 ; digit = edx+'0' ; store at --edi } while (eax != 0)
print from edi, length = end - edi
```
- **Purpose:** show any unsigned number in decimal; there is no `printf`.
- **If `xor edx, edx` before `div` were missing:** 💥 `div ebx` divides **EDX:EAX** (64-bit). Leftover garbage in EDX makes the quotient too big for 32 bits → **divide error (SIGFPE)** or wrong digits.
- **If `add dl, '0'` were missing:** ❌ you'd print byte values 0–9 (invisible control characters) instead of the characters '0'–'9'.
- **Why fill backwards?** `div` produces the **last** digit first; writing from the right end puts them in the correct order with no reversing.
- **Why `test eax,eax / jnz` at the bottom (do-while)?** So that the number `0` still prints one digit "0".
- **Length = end − edi:** avoids leading-zero padding.

### 12.4 `print_money` (L761–777)
- **Purpose:** show cents as `RM x.xx`.
- **How:** `div` by 100 → EAX = ringgit, EDX = sen; print `RM `, ringgit, `.`, sen.
- **If the "print `0` when sen < 10" were missing:** ❌ **5 sen would print as `.5` – which reads as 50 sen**. It's a real money-reading bug (RM 2.05 shown as RM 2.5).
- **If `xor edx,edx` were missing:** 💥 divide error, same as above.
- **`mov esi, edx`:** parks the sen while `print_num` uses EAX/EDX. It's safe because every routine preserves ESI via `pushad`.

### 12.5 `read_line` (L783–807)
- **Purpose:** read one line from the keyboard into `input_buf` (NUL-terminated, without the newline).
- **How:** `sys_read` **1 byte at a time**.

| Detail | Purpose | If missing |
|---|---|---|
| 1 byte per `sys_read` | Works with typed **and piped** input; never over-reads past the newline | ❌ Reading a big block could swallow the next line's data |
| `cmp eax,1 / jne quit` | EOF (0) or error (negative) → exit | 💥 On EOF (Ctrl+D or piped input ended) `char_buf` keeps its old value, so the loop **runs forever** |
| `cmp al,10 / je .done` | Newline ends the line | 💥 The line would never finish |
| `cmp al,13 / je .next_char` | Ignore CR (Windows line endings) | ❌ stray CR stored → "123\r" isn't all digits → valid numbers rejected |
| `cmp esi,INPUT_MAX / jae .next_char` | Discard characters beyond 63 | 💥 Buffer overflow into `char_buf` and `name_tmp`... and also long input "leaks" into the next prompt |
| `mov byte [input_buf+esi], 0` | NUL-terminate | ❌ Leftover text from the previous input would remain: type "123", then "7" → buffer "723" |

### 12.6 `atoi` (L811–841) – text → number
```
value = 0 ; digits = 0
for each char: digit = ch - '0' ; if digit > 9: bad
               value = value*10 + digit ; digits++ ; if digits > 9: bad
at NUL: if digits == 0: bad
EAX(saved) = value ; CF = 0
```

| Line(s) | Purpose | If missing |
|---|---|---|
| `movzx edx, byte [esi]` | Load one char as a 32-bit value | ❌ Using `mov edx,[esi]` would load 4 bytes (including the next chars) |
| `sub edx,'0'` + `cmp edx,9 / ja .bad` | Digit test in **one** compare (chars below '0' wrap to a huge unsigned number) | ❌ Letters/symbols accepted as digits → "1a" gives a nonsense number |
| `lea eax,[eax+eax*4]` + `add eax,eax` | value × 10 without `mul` (×5 then ×2) | ❌ Value wouldn't scale → "123" would equal 6 |
| `cmp ecx,9 / ja .bad` | Max 9 digits: 999,999,999 fits in 32 bits (limit ≈ 4.29 billion) | ❌ 10+ digit input silently **overflows** (wraps) to a small bogus number |
| `test ecx,ecx / jz .bad` | Empty input is invalid | ❌ A blank line would be accepted as 0 |
| `mov [esp+28], eax` | Put the result into the **saved EAX** so `popad` loads it into EAX | ❌ The result would be thrown away: `popad` restores the old EAX and the caller sees no number |
| `clc` / `stc` | Report success or failure in CF | ❌ Callers' `jc` would test a leftover CF |

**Why does `[esp+28]` work?** `pushad` pushes EAX first, so it ends up deepest = at offset 28 from the final ESP. (Order: EAX ECX EDX EBX ESP EBP ESI EDI.)

### 12.7 `read_number` (L844–847)
- **Purpose:** convenience: `read_line` + `atoi`, so every prompt is a single call.
- **If missing:** ✅ works if each caller used the two calls itself, but 🎨 there'd be ~10 duplicated pairs.

---

## 13. Cross-cutting design features and why they matter

| Feature | Where | What it gives you | Without it |
|---|---|---|---|
| `PUSHAD` / `POPAD` everywhere | all routines | Callers can keep values in any register across a `call` (e.g. EBX = product index across many `PRINT`/`read_number` calls) | Every routine would need to document which registers it breaks; very error-prone ❌ |
| Carry flag as the result | `atoi`, `name_contains`, `read_number` | Cheap success/fail signal that survives `popad`/`ret` | Need an extra register/memory variable ❌/🎨 |
| Value return via `[esp+28]` | `atoi` | Return a number through `POPAD` | Result would be lost ❌ |
| Integer cents | whole program | Exact arithmetic with only ADD/SUB/CMP | Floating-point errors and the FPU (complex) |
| Parallel arrays + `[base+index*4]` | all product code | Simple "database" with scaled-index addressing | Need structs/pointers – harder in assembly |
| Jump table | `main_loop` | One-line dispatch | 7 compare-and-jump pairs 🎨 |
| Validate-then-re-ask loops | every prompt | Program never continues with bad data | Crashes/wrong data from typos ❌ |
| Commit-last pattern | `add_product`, `process_sale`, `restock` | Cancelled/failed actions change nothing | Half-updated data ❌ |
| Constants (`EQU`) | everywhere | Change a limit in one place | Magic numbers scattered 🎨 |
| Reuse (`print_product_row`, `PRINT`, `print_money`) | everywhere | Less code, consistent output | Duplicate code and inconsistent output 🎨 |

---

## 14. Quick severity ranking: "most dangerous things to remove"

| Rank | Removal | Result |
|---|---|---|
| 1 | The `int 0x80` exit in `quit` | 💥 runs into the next routine, crashes |
| 2 | `xor edx,edx` before `div` | 💥 divide error when printing numbers |
| 3 | Range check before the jump table (`cmp 1` / `cmp 7`) | 💥 jump to garbage address |
| 4 | A `popad` without its `pushad` (or vice-versa) | 💥 `ret` goes to a wrong address |
| 5 | Qty-zero check before `.mul_loop` | 💥 ~4 billion iterations |
| 6 | EOF check in `read_line` | 💥 infinite loop at end of input |
| 7 | `inc dword [product_count]` in `add_product` | ❌ new product invisible |
| 8 | Reservation loop in `process_sale` | ❌ overselling → stock wraps to ≈ 4 billion |
| 9 | `jb .short_cash` | ❌ bogus giant change |
| 10 | `[esp+28]` write in `atoi` | ❌ every number read is lost |
| 11 | "print `0` for sen < 10" | ❌ RM 2.05 shown as RM 2.5 |
| 12 | `to_lower` range check | ❌ search fails |
| 13 | `cld`, `clc` | ✅ probably no visible effect |

---

## 15. Using this in the interview

For any block your lecturer points at, answer in this order:
1. **"This block is used to…"** (purpose)
2. **"It works by…"** (mechanism, with one concrete number)
3. **"If it weren't there…"** (consequence – pick from the tables above)

Example (`test eax,eax / jz .add_loop` after reading the quantity):
> "This checks whether the quantity is zero, meaning the user wants to drop the line. It works because `test eax,eax` sets the zero flag only when EAX is 0. If it weren't there, a quantity of 0 would reach `loop` with ECX = 0; `loop` decrements first, so it would wrap to 0xFFFFFFFF and repeat about 4 billion times."
