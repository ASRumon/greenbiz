<#
.SYNOPSIS
  End-to-end smoke test for the GreenBiz Worker.

.DESCRIPTION
  Exercises the whole demo path against a running `wrangler dev`:
      register -> shop -> product -> SMS upload -> transactions -> credit score -> AI advice

  Also asserts the things that are easy to get wrong and expensive to miss:
    * SMS bulk upload is idempotent (re-uploading the same inbox adds nothing)
    * protected routes reject a missing / malformed bearer token
    * every error response uses the { error: { code, message } } shape
    * money round-trips as integer minor units, not floats

.USAGE
  In one terminal:   npm run dev
  In another:        powershell -File scripts/smoke-test.ps1

  The admin-token check is skipped if .dev.vars is absent.
#>
param(
    [string]$BaseUrl = "http://127.0.0.1:8787",
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$script:WorkerDir = Split-Path -Parent $PSScriptRoot

function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host ("  [PASS] " + $Name) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [FAIL] " + $Name + " :: " + $Detail) -ForegroundColor Red
        $script:Failed++
    }
}

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body,
        [string]$Token
    )
    $headers = @{ "Content-Type" = "application/json" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }
    $uri = $BaseUrl + $Path
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers }
    if ($null -ne $Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 12) }
    return Invoke-RestMethod @params
}

function Get-StatusCode {
    param([scriptblock]$Block)
    try {
        & $Block | Out-Null
        return 200
    }
    catch {
        $response = $_.Exception.Response
        if ($response) { return [int]$response.StatusCode }
        return 0
    }
}

Write-Host ""
Write-Host "GreenBiz API smoke test -> $BaseUrl" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- health -----
Write-Host "health"
$health = Invoke-Api -Method GET -Path "/api/health"
Assert "GET /api/health returns ok" ($health.ok -eq $true) "ok=$($health.ok)"
Assert "D1 binding is present" ($health.database -eq "bound") "database=$($health.database)"
Assert "health reports AI availability" ($health.aiConfigured -ne $null) "aiConfigured missing"

# ------------------------------------------------------------ auth: wrong ---
Write-Host "auth guards"
$noTokenStatus = Get-StatusCode { Invoke-Api -Method GET -Path "/api/auth/me" }
Assert "GET /api/auth/me without a token is 401" ($noTokenStatus -eq 401) "got $noTokenStatus"

$badTokenStatus = Get-StatusCode { Invoke-Api -Method GET -Path "/api/auth/me" -Token "not-a-real-jwt" }
Assert "malformed JWT is 401" ($badTokenStatus -eq 401) "got $badTokenStatus"

# ------------------------------------------------------------- auth: happy ---
$suffix = -join ((1..6) | ForEach-Object { "0123456789abcdef"[(Get-Random -Max 16)] })
$username = "smoke_$suffix"
$password = "SmokeTest!$suffix"

Write-Host "auth flow ($username)"
$registered = Invoke-Api -Method POST -Path "/api/auth/register" -Body @{
    fullName     = "Smoke Tester"
    username     = $username
    email        = "$username@example.com"
    password     = $password
    shopName     = "Smoke Shop $suffix"
    businessType = "retail"
}
Assert "register returns a token" ([bool]$registered.token) "no token"
Assert "register returns the user" ($registered.user.username -eq $username) "username mismatch"
Assert "register never returns a password hash" ($null -eq $registered.user.passwordHash) "passwordHash leaked!"
Assert "register provisions a shop" ([bool]$registered.shopId) "no shopId"
$token = $registered.token
$shopId = $registered.shopId

$login = Invoke-Api -Method POST -Path "/api/auth/login" -Body @{ username = $username; password = $password }
Assert "login with the right password succeeds" ([bool]$login.token) "no token"

$wrongStatus = Get-StatusCode {
    Invoke-Api -Method POST -Path "/api/auth/login" -Body @{ username = $username; password = "definitely-wrong" }
}
Assert "login with the wrong password is 401" ($wrongStatus -eq 401) "got $wrongStatus"

$me = Invoke-Api -Method GET -Path "/api/auth/me" -Token $token
Assert "GET /api/auth/me returns the user" ($me.user.username -eq $username) "mismatch"
Assert "GET /api/auth/me lists the owned shop" ($me.shops.Count -ge 1) "shops=$($me.shops.Count)"

# ------------------------------------------------------------- validation ----
Write-Host "validation"
$shortPasswordStatus = Get-StatusCode {
    Invoke-Api -Method POST -Path "/api/auth/register" -Body @{ fullName = "X Y"; username = "vb$suffix"; password = "short" }
}
Assert "a too-short password is 400" ($shortPasswordStatus -eq 400) "got $shortPasswordStatus"

$errorShapeStatus = $null
try {
    Invoke-Api -Method POST -Path "/api/auth/register" -Body @{ fullName = "X Y"; username = "vb$suffix"; password = "short" } | Out-Null
}
catch {
    $payload = $_.ErrorDetails.Message | ConvertFrom-Json
    $errorShapeStatus = [bool]($payload.error.code -and $payload.error.message)
}
Assert "errors use { error: { code, message } }" ($errorShapeStatus -eq $true) "unexpected shape"

# -------------------------------------------------------------- inventory ----
Write-Host "inventory"
$product = Invoke-Api -Method POST -Path "/api/shops/$shopId/products" -Token $token -Body @{
    productName    = "Aromatic Rice 5kg"
    unit           = "bag"
    unitPriceMinor = 95000
    stockQuantity  = 24
}
Assert "create product returns the row" ($product.product.productName -eq "Aromatic Rice 5kg") "name mismatch"
Assert "price is stored as integer minor units" ($product.product.unitPriceMinor -eq 95000) "got $($product.product.unitPriceMinor)"
Assert "price is an integer, not a float" ((($product.product.unitPriceMinor % 1) -eq 0)) "fractional minor units!"
$productId = $product.product.id

$patched = Invoke-Api -Method PATCH -Path "/api/products/$productId" -Token $token -Body @{ stockQuantity = 30 }
Assert "patch product updates stock" ($patched.product.stockQuantity -eq 30) "got $($patched.product.stockQuantity)"

$listed = Invoke-Api -Method GET -Path "/api/shops/$shopId/products" -Token $token
Assert "list products returns the new row" ($listed.products.Count -ge 1) "count=$($listed.products.Count)"

# ------------------------------------------------------------------- sms -----
Write-Host "sms ingestion (the demo path)"
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$day = 86400000

# The exact bKash sample supplied for this build, plus Nagad / Rocket / UPI and
# one message that is deliberately not a payment.
$messages = @(
    @{ sender = "16247"; body = "You have received Tk 1,500.00 from 01782665484. Fee Tk 0.00. Balance Tk 1,699.05. TrxID DJG73D7KLD at 16/10/2026 15:46"; receivedAt = $now - (2 * $day) },
    @{ sender = "16247"; body = "You have sent Tk 500.00 to 01712345678. Fee Tk 0.00. Balance Tk 1,199.05. TrxID ABC123XYZ at 16/10/2026 16:10"; receivedAt = $now - (2 * $day) + 60000 },
    @{ sender = "16248"; body = "You have received Tk 850.00 from 01722334455. Your new balance is Tk 2,049.05. TrxID: 9988776655"; receivedAt = $now - (9 * $day) },
    @{ sender = "16216"; body = "You have received Tk 1,000.00 from 01733445566. Reference: 123456789012. Your new balance: Tk 3,049.05"; receivedAt = $now - (20 * $day) },
    @{ sender = "VM-HDFCBK"; body = "Rs.500.00 credited to your A/c XXXX1234 on 16-10-2026. UPI Ref 445566778899"; receivedAt = $now - (5 * $day) },
    @{ sender = "16247"; body = "You have received Tk 1,250.00 from 01744556677. TrxID QQ11WW22EE at 16/10/2026 18:02"; receivedAt = $now - (35 * $day) },
    @{ sender = "16247"; body = "You have received Tk 1,400.00 from 01755667788. TrxID ZZ33XX44CC at 16/10/2026 11:20"; receivedAt = $now - (62 * $day) },
    @{ sender = "PERSONAL"; body = "Hey, are we still meeting for tea at 5pm today?"; receivedAt = $now - (3 * $day) }
)

$bulk = Invoke-Api -Method POST -Path "/api/shops/$shopId/sms/bulk" -Token $token -Body @{ messages = $messages }
Assert "bulk upload accepts the batch" ($bulk.summary.received -eq $messages.Count) "got $($bulk.summary.received)"
Assert "7 payment SMS parsed" ($bulk.summary.parsed -eq 7) "parsed=$($bulk.summary.parsed)"
Assert "the non-payment SMS is rejected, not stored as a transaction" ($bulk.summary.notPayment -ge 1) "notPayment=$($bulk.summary.notPayment)"
Assert "transactions were created from the SMS" ($bulk.summary.transactionsCreated -eq 7) "created=$($bulk.summary.transactionsCreated)"
Assert "tier-1 regex handled all 7 (no LLM cost)" ($bulk.summary.bySource.regex -eq 7) "regex=$($bulk.summary.bySource.regex) llm=$($bulk.summary.bySource.llm)"
Assert "credit score was recomputed during ingest" ($null -ne $bulk.summary.score) "score missing"

$sampleResult = $bulk.results | Where-Object { $_.outcome -eq "inserted" } | Select-Object -First 1
Assert "each result reports its parse source" ($null -ne $sampleResult.parseSource) "missing parseSource"

# The headline assertion: the exact supplied bKash SMS maps to the right fields.
$parsed = Invoke-Api -Method POST -Path "/api/ai/parse-sms" -Token $token -Body @{
    sender = "16247"
    body   = "You have received Tk 1,500.00 from 01782665484. Fee Tk 0.00. Balance Tk 1,699.05. TrxID DJG73D7KLD at 16/10/2026 15:46"
}
Assert "bKash sample: direction is 'in'" ($parsed.extract.direction -eq "in") "got $($parsed.extract.direction)"
Assert "bKash sample: amountMinor is 150000 (Tk 1,500.00)" ($parsed.extract.amountMinor -eq 150000) "got $($parsed.extract.amountMinor)"
Assert "bKash sample: counterparty is the sender number" ($parsed.extract.counterparty -eq "01782665484") "got $($parsed.extract.counterparty)"
Assert "bKash sample: reference is the TrxID" ($parsed.extract.reference -eq "DJG73D7KLD") "got $($parsed.extract.reference)"
Assert "bKash sample: handled by tier 1 (regex)" ($parsed.tier -eq 1) "tier=$($parsed.tier)"

$outSample = Invoke-Api -Method POST -Path "/api/ai/parse-sms" -Token $token -Body @{
    sender = "16247"
    body   = "You have sent Tk 500.00 to 01712345678. Fee Tk 0.00. Balance Tk 1,199.05. TrxID ABC123XYZ at 16/10/2026 16:10"
}
Assert "sent SMS: direction is 'out'" ($outSample.extract.direction -eq "out") "got $($outSample.extract.direction)"

$nagadSample = Invoke-Api -Method POST -Path "/api/ai/parse-sms" -Token $token -Body @{
    sender = "16248"
    body   = "You have received Tk 850.00 from 01722334455. Your new balance is Tk 2,049.05. TrxID: 9988776655"
}
Assert "Nagad SMS parses" ($nagadSample.extract.amountMinor -eq 85000) "got $($nagadSample.extract.amountMinor)"

$upiSample = Invoke-Api -Method POST -Path "/api/ai/parse-sms" -Token $token -Body @{
    sender = "VM-HDFCBK"
    body   = "Rs.500.00 credited to your A/c XXXX1234 on 16-10-2026. UPI Ref 445566778899"
}
Assert "UPI SMS parses as INR" ($upiSample.currency -eq "INR") "got $($upiSample.currency)"

$junk = Invoke-Api -Method POST -Path "/api/ai/parse-sms" -Token $token -Body @{
    sender = "PERSONAL"
    body   = "Hey, are we still meeting for tea at 5pm today?"
}
Assert "a non-payment SMS is reported as not_payment" ($junk.parseStatus -eq "failed") "got $($junk.parseStatus)"

# ------------------------------------------------------------ idempotency ----
$again = Invoke-Api -Method POST -Path "/api/shops/$shopId/sms/bulk" -Token $token -Body @{ messages = $messages }
Assert "re-uploading the same inbox inserts nothing" ($again.summary.inserted -eq 0) "inserted=$($again.summary.inserted)"
Assert "re-uploading the same inbox reports duplicates" ($again.summary.duplicates -eq $messages.Count) "duplicates=$($again.summary.duplicates)"
Assert "re-uploading creates no duplicate transactions" ($again.summary.transactionsCreated -eq 0) "created=$($again.summary.transactionsCreated)"

# ----------------------------------------------------------- transactions ----
Write-Host "transactions"
$txs = Invoke-Api -Method GET -Path "/api/shops/$shopId/transactions" -Token $token
Assert "7 transactions exist" ($txs.transactions.Count -eq 7) "count=$($txs.transactions.Count)"
Assert "totals include inflow" ($txs.totals.inMinor -eq 650000) "inMinor=$($txs.totals.inMinor)"
Assert "totals include outflow" ($txs.totals.outMinor -eq 50000) "outMinor=$($txs.totals.outMinor)"
Assert "all amounts are integers" ((($txs.transactions | Where-Object { $_.amountMinor % 1 -ne 0 }).Count -eq 0)) "fractional amount found"

$manual = Invoke-Api -Method POST -Path "/api/shops/$shopId/transactions" -Token $token -Body @{
    direction    = "in"
    amountMinor  = 250000
    currency     = "BDT"
    counterparty = "Walk-in customer"
    note         = "Cash sale"
}
Assert "manual transaction can be created" ($manual.transaction.amountMinor -eq 250000) "amount mismatch"
Assert "manual transaction has no sms_id" ($null -eq $manual.transaction.smsId) "smsId should be null"

$deleted = Invoke-Api -Method DELETE -Path "/api/transactions/$($manual.transaction.id)" -Token $token
Assert "manual transaction can be deleted" ($deleted.deleted -eq $true) "not deleted"

# ---------------------------------------------------- sales + cash-out -------
Write-Host "sales (the cash-out band)"

# A shirt priced at 990.00 taka, so a 1,000.00 taka payment is 10 taka over:
# that is the 1% cash-out charge inside the 2% band the app and the Worker share.
$shirt = Invoke-Api -Method POST -Path "/api/shops/$shopId/products" -Token $token -Body @{
    productName    = "Cotton shirt"
    unit           = "piece"
    unitPriceMinor = 99000
    stockQuantity  = 5
}
$shirtId = $shirt.product.id

$smsThousand = $txs.transactions | Where-Object { $_.amountMinor -eq 100000 -and $_.direction -eq "in" } | Select-Object -First 1
$smsFifteen = $txs.transactions | Where-Object { $_.amountMinor -eq 150000 -and $_.direction -eq "in" } | Select-Object -First 1

$linked = Invoke-Api -Method POST -Path "/api/shops/$shopId/sales" -Token $token -Body @{
    items         = @(@{ productId = $shirtId; quantity = 1 })
    paymentMethod = "bkash"
    smsId         = $smsThousand.smsId
}
Assert "a payment carrying the cash-out charge merges into the sale" ($linked.smsLinked -eq $true) "smsLinked=$($linked.smsLinked)"
Assert "the merged row keeps what the customer actually sent" ($linked.transaction.amountMinor -eq 100000) "got $($linked.transaction.amountMinor)"
Assert "the merged row is the SMS row, not a new one" ($linked.transaction.id -eq $smsThousand.id) "id changed"
Assert "linking does not book a second inflow" (($linked.totalMinor -eq 99000)) "total=$($linked.totalMinor)"

$afterLink = Invoke-Api -Method GET -Path "/api/shops/$shopId/transactions" -Token $token
Assert "the ledger still has 7 rows after the merge" ($afterLink.transactions.Count -eq 7) "count=$($afterLink.transactions.Count)"

$stockAfter = Invoke-Api -Method GET -Path "/api/shops/$shopId/products" -Token $token
$shirtStock = ($stockAfter.products | Where-Object { $_.id -eq $shirtId }).stockQuantity
Assert "the merged sale still takes the stock down" ($shirtStock -eq 4) "stock=$shirtStock"

$farOff = Invoke-Api -Method POST -Path "/api/shops/$shopId/sales" -Token $token -Body @{
    items         = @(@{ productId = $shirtId; quantity = 1 })
    paymentMethod = "bkash"
    smsId         = $smsFifteen.smsId
}
Assert "a payment from another sale is not merged" ($farOff.smsLinked -ne $true) "smsLinked=$($farOff.smsLinked)"

$afterFarOff = Invoke-Api -Method GET -Path "/api/shops/$shopId/transactions" -Token $token
Assert "an unrelated payment leaves its row alone and adds the sale" ($afterFarOff.transactions.Count -eq 8) "count=$($afterFarOff.transactions.Count)"

# ---------------------------------------------------------------- credit -----
Write-Host "credit"
$credit = Invoke-Api -Method GET -Path "/api/shops/$shopId/credit" -Token $token
$profile = $credit.creditProfile
Assert "credit score is 0-100" (($profile.score -ge 0) -and ($profile.score -le 100)) "score=$($profile.score)"
Assert "credit profile has 4 factors" ($profile.factors.Count -eq 4) "count=$($profile.factors.Count)"
$weightSum = ($profile.factors | Measure-Object -Property weight -Sum).Sum
Assert "factor weights sum to 1.0" ([Math]::Abs($weightSum - 1.0) -lt 0.0001) "sum=$weightSum"
Assert "risk flags is a list" ($null -ne $profile.riskFlags) "riskFlags missing"

# Derived from the ledger rather than hard-coded: the sales section above adds
# rows, and this assertion is about the window, not about the count.
$cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - (90 * $day)
$inWindow = @($afterFarOff.transactions | Where-Object { $_.occurredAt -ge $cutoff }).Count
Assert "transaction count reflects the 90-day window" ($profile.transactionCount90d -eq $inWindow) "expected=$inWindow got=$($profile.transactionCount90d)"

$recomputed = Invoke-Api -Method POST -Path "/api/shops/$shopId/credit/recompute" -Token $token
Assert "recompute is deterministic" ($recomputed.creditProfile.score -eq $profile.score) "score changed between calls"

# ------------------------------------- split payment + rounded bill ---------
# A bill the shopkeeper rounds down, and a bill paid part bKash / part cash.
Write-Host "sales (split payment and rounded bill)"

$onion = Invoke-Api -Method POST -Path "/api/shops/$shopId/products" -Token $token -Body @{
    productName    = "Onion"
    unit           = "kg"
    unitPriceMinor = 25700
    stockQuantity  = 10
}
$onionId = $onion.product.id

$roundReceivedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-Api -Method POST -Path "/api/shops/$shopId/sms/bulk" -Token $token -Body @{
    messages = @(@{
            sender     = "16247"
            body       = "You have received Tk 250.00 from 01711111111. TrxID ROUND250A at 19/10/2026 10:00"
            receivedAt = $roundReceivedAt
        })
} | Out-Null

$afterRoundSms = Invoke-Api -Method GET -Path "/api/shops/$shopId/transactions" -Token $token
$roundTx = $afterRoundSms.transactions |
Where-Object { $_.amountMinor -eq 25000 -and $_.direction -eq "in" } |
Select-Object -First 1

$rounded = Invoke-Api -Method POST -Path "/api/shops/$shopId/sales" -Token $token -Body @{
    items         = @(@{ productId = $onionId; quantity = 1 })
    paymentMethod = "bkash"
    smsId         = $roundTx.smsId
    payableMinor  = 25000
}
Assert "a rounded bill reports the catalogue bill" ($rounded.subtotalMinor -eq 25700) "subtotal=$($rounded.subtotalMinor)"
Assert "a rounded bill reports the discount" ($rounded.discountMinor -eq 700) "discount=$($rounded.discountMinor)"
Assert "the collected amount is the rounded total" ($rounded.totalMinor -eq 25000) "total=$($rounded.totalMinor)"
Assert "a 250 SMS matches the 250 rounded total" ($rounded.smsLinked -eq $true) "smsLinked=$($rounded.smsLinked)"
Assert "the ledger row carries the discount" ($rounded.transaction.discountMinor -eq 700) "row=$($rounded.transaction.discountMinor)"
Assert "the ledger row carries the bill" ($rounded.transaction.subtotalMinor -eq 25700) "row=$($rounded.transaction.subtotalMinor)"
Assert "the rounded row is the SMS row" ($rounded.transaction.id -eq $roundTx.id) "id changed"
Assert "the cash row is absent on a rounded sale" ($null -eq $rounded.cashTransaction) "unexpected cash row"

# Part bKash, part cash: ৳30 received + ৳10 handed over for a ৳40 sale.
$rice = Invoke-Api -Method POST -Path "/api/shops/$shopId/products" -Token $token -Body @{
    productName    = "Rice"
    unit           = "kg"
    unitPriceMinor = 4000
    stockQuantity  = 10
}
$riceId = $rice.product.id

$splitReceivedAt = $roundReceivedAt + 1000
Invoke-Api -Method POST -Path "/api/shops/$shopId/sms/bulk" -Token $token -Body @{
    messages = @(@{
            sender     = "16247"
            body       = "You have received Tk 30.00 from 01722222222. TrxID SPLIT30A at 19/10/2026 10:05"
            receivedAt = $splitReceivedAt
        })
} | Out-Null

$afterSplitSms = Invoke-Api -Method GET -Path "/api/shops/$shopId/transactions" -Token $token
$splitTx = $afterSplitSms.transactions |
Where-Object { $_.amountMinor -eq 3000 -and $_.direction -eq "in" } |
Select-Object -First 1

$saleId = [guid]::NewGuid().ToString()
$splitBody = @{
    id            = $saleId
    items         = @(@{ productId = $riceId; quantity = 1 })
    paymentMethod = "bkash"
    smsId         = $splitTx.smsId
    payableMinor  = 4000
    cashMinor     = 1000
}
$split = Invoke-Api -Method POST -Path "/api/shops/$shopId/sales" -Token $token -Body $splitBody
Assert "a short message plus cash links to the sale" ($split.smsLinked -eq $true) "smsLinked=$($split.smsLinked)"
Assert "the split books the cash balance" ($split.cashMinor -eq 1000) "cash=$($split.cashMinor)"
Assert "the cash row has the cash amount" ($split.cashTransaction.amountMinor -eq 1000) "row=$($split.cashTransaction.amountMinor)"
Assert "the two parts add up to the sale total" (($split.transaction.amountMinor + $split.cashMinor) -eq 4000) "parts did not add up"
Assert "cash is recorded as the cash method" ($split.cashTransaction.paymentMethod -eq "cash") "method=$($split.cashTransaction.paymentMethod)"
Assert "the split ledger row carries the bill" ($split.transaction.subtotalMinor -eq 4000) "row=$($split.transaction.subtotalMinor)"

$splitRows = (Invoke-Api -Method GET -Path "/api/shops/$shopId/transactions" -Token $token).transactions |
Where-Object { $_.saleId -eq $saleId }
Assert "a split sale writes exactly two ledger rows" ($splitRows.Count -eq 2) "count=$($splitRows.Count)"

$splitRetry = Invoke-Api -Method POST -Path "/api/shops/$shopId/sales" -Token $token -Body $splitBody
Assert "retrying a split sale returns the same cash balance" ($splitRetry.cashMinor -eq 1000) "cash=$($splitRetry.cashMinor)"

$riceStock = ((Invoke-Api -Method GET -Path "/api/shops/$shopId/products" -Token $token).products |
    Where-Object { $_.id -eq $riceId }).stockQuantity
Assert "retrying a split sale does not take stock twice" ($riceStock -eq 9) "stock=$riceStock"

# -------------------------------------------------------- loan matching ------
Write-Host "plan matching"
$matched = Invoke-Api -Method GET -Path "/api/shops/$shopId/matched-plans" -Token $token
Assert "matched-plans returns a list" ($null -ne $matched.matches) "matches missing"
Assert "matched-plans explains itself" ([bool]$matched.message) "no message"
Assert "matched-plans returns the capacity estimate" ($null -ne $matched.capacity) "capacity missing"
if ($matched.matches.Count -gt 0) {
    $priorities = @($matched.matches | ForEach-Object { $_.priority })
    $badPriorities = @($priorities | Where-Object { $_ -notin @('high', 'medium', 'low', 'unknown') })
    Assert "priorities use the documented bands" ($badPriorities.Count -eq 0) "bad=$($badPriorities -join ',')"

    $highPlans = @($matched.matches | Where-Object { $_.priority -eq 'high' })
    $badHigh = @($highPlans | Where-Object { $null -ne $_.affordabilityRatio -and $_.affordabilityRatio -lt 2 })
    Assert "every high-priority plan covers the instalment at least 2x" ($badHigh.Count -eq 0) "bad=$($badHigh.Count)"
}

# ------------------------------------------------------------------ admin ----
# Seeding runs BEFORE the directory checks: a smoke test should be
# self-contained, not depend on someone having run `npm run seed` first.
Write-Host "admin seed"
$devVarsPath = Join-Path $script:WorkerDir ".dev.vars"
$adminToken = $null
if (Test-Path $devVarsPath) {
    foreach ($line in (Get-Content $devVarsPath)) {
        if ($line -match '^\s*ADMIN_TOKEN\s*=\s*(.+)$') { $adminToken = $Matches[1].Trim() }
    }
}

if ($adminToken) {
    $userSeedStatus = Get-StatusCode { Invoke-Api -Method POST -Path "/api/admin/seed" -Token $token }
    Assert "a normal user token cannot seed (401)" ($userSeedStatus -eq 401) "got $userSeedStatus"

    $seedResult = Invoke-Api -Method POST -Path "/api/admin/seed" -Token $adminToken
    Assert "admin seed runs with the admin token" ($seedResult.ok -eq $true) "ok=$($seedResult.ok)"
    Assert "admin seed loads the 8 banks" ($seedResult.institutions -ge 8) "institutions=$($seedResult.institutions)"
    Assert "admin seed loads the loan catalogue" ($seedResult.plans -ge 39) "plans=$($seedResult.plans)"

    $matchedAfterSeed = Invoke-Api -Method GET -Path "/api/shops/$shopId/matched-plans" -Token $token
    Assert "matching finds plans once the catalogue is loaded" ($matchedAfterSeed.matches.Count -ge 1) "matches=$($matchedAfterSeed.matches.Count)"
}
else {
    Write-Host "  [SKIP] ADMIN_TOKEN not set in .dev.vars" -ForegroundColor Yellow
}

# ------------------------------------------------------------- directory -----
Write-Host "public directory"
$institutions = Invoke-Api -Method GET -Path "/api/institutions"
Assert "institutions are listed (seeded)" ($institutions.institutions.Count -ge 8) "count=$($institutions.institutions.Count)"

$plans = Invoke-Api -Method GET -Path "/api/plans" -Token $token
Assert "plans are listed (seeded)" ($plans.plans.Count -ge 15) "count=$($plans.plans.Count)"

$loans = Invoke-Api -Method GET -Path "/api/plans?serviceType=loan" -Token $token
Assert "plans filter by serviceType" ($loans.plans.Count -ge 1) "count=$($loans.plans.Count)"
Assert "filtered plans are all loans" ((($loans.plans | Where-Object { $_.serviceType -ne "loan" }).Count -eq 0)) "non-loan returned"

# Guarded: if the directory is empty the run should report that as a failure and
# carry on, not abort with a null plan id.
if ($plans.plans.Count -gt 0) {
    $firstPlan = $plans.plans[0]
    $planDetail = Invoke-Api -Method GET -Path "/api/plans/$($firstPlan.id)" -Token $token
    Assert "plan detail embeds the institution" ([bool]$planDetail.plan.institution.name) "no institution"
    Assert "plan eligibility JSON is decoded" ($null -ne $planDetail.plan.eligibility) "eligibility not parsed"
}
else {
    Write-Host "  [SKIP] plan detail checks need a seeded catalogue" -ForegroundColor Yellow
}

# ------------------------------------------------------------- ai status -----
Write-Host "ai"
$aiStatus = Invoke-Api -Method GET -Path "/api/ai/status" -Token $token
Assert "ai status never returns a key" ($null -eq $aiStatus.GEMINI_API_KEY) "key leaked"

if ($aiStatus.available) {
    $advice = Invoke-Api -Method POST -Path "/api/ai/recommend" -Token $token -Body @{ shopId = $shopId; intent = "loan" }
    Assert "ai/recommend returns advice" ([bool]$advice.advice) "no advice text"
    Assert "ai/recommend returns a planIds array" ($null -ne $advice.planIds) "planIds missing"
}
else {
    Write-Host "  [SKIP] ai/recommend needs GEMINI_API_KEY in .dev.vars" -ForegroundColor Yellow
}

# ----------------------------------------------------------- cross-tenant ----
Write-Host "tenant isolation"
$otherName = "smoke2_$suffix"
$other = Invoke-Api -Method POST -Path "/api/auth/register" -Body @{
    fullName = "Other Tester"; username = $otherName; password = $password; shopName = "Other Shop"
}
$crossStatus = Get-StatusCode { Invoke-Api -Method GET -Path "/api/shops/$shopId/products" -Token $other.token }
Assert "another user cannot read this shop's products (404)" ($crossStatus -eq 404) "got $crossStatus"

$crossWriteStatus = Get-StatusCode {
    Invoke-Api -Method POST -Path "/api/shops/$shopId/products" -Token $other.token -Body @{
        productName = "Sneaky"; unit = "pc"; unitPriceMinor = 100; stockQuantity = 1
    }
}
Assert "another user cannot write to this shop (404)" ($crossWriteStatus -eq 404) "got $crossWriteStatus"

# ------------------------------------------------------------------ result ---
Write-Host ""
if ($script:Failed -eq 0) {
    Write-Host ("ALL " + $script:Passed + " CHECKS PASSED") -ForegroundColor Green
    exit 0
}
Write-Host ("FAILED: " + $script:Failed + " of " + ($script:Passed + $script:Failed) + " checks") -ForegroundColor Red
exit 1
