<#
.SYNOPSIS
  Provisions a demo account with realistic test data on a GreenBiz deployment.

.DESCRIPTION
  Creates (or reuses) a user, a shop, an inventory, and about three months of
  mobile-money SMS history, so the Finance tab has a meaningful credit profile
  instead of an empty state.

  It goes through the public HTTP API rather than inserting rows with SQL. That
  is deliberate: it means the data is created by exactly the same code path a
  real user hits, so a bug in validation, parsing, or scoring shows up here.

  IDEMPOTENT. Re-running it is safe:
    * the account is reused if it already exists (login, not register)
    * products are only added if a product with that name is missing
    * SMS timestamps are anchored to UTC day boundaries, so the server's
      (shop_id, sender, body, received_at) unique index rejects the duplicates
    * manual transactions are guarded by a marker note

.PARAMETER Password
  The demo account's password. There is deliberately no default: pass -Password
  or set the GREENBIZ_DEMO_PASSWORD environment variable. Keeping it out of this
  file means the repository never carries a live credential.

.USAGE
  $env:GREENBIZ_DEMO_PASSWORD = '<the demo password>'
  powershell -File scripts/seed-demo-account.ps1

  powershell -File scripts/seed-demo-account.ps1 -BaseUrl https://greenbiz.asrumon.workers.dev/api -Password '<the demo password>'
#>
param(
    [string]$BaseUrl = 'https://greenbiz.asrumon.workers.dev/api',
    [string]$Username = 'demo',
    [string]$Password = $env:GREENBIZ_DEMO_PASSWORD,
    [string]$FullName = 'Karim Uddin',
    [string]$ShopName = 'Karim General Store'
)

if ([string]::IsNullOrWhiteSpace($Password)) {
    throw 'The demo password is required: pass -Password "<password>" or set $env:GREENBIZ_DEMO_PASSWORD. It is intentionally not stored in this script.'
}

$ErrorActionPreference = 'Stop'

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body,
        [string]$Token,
        [switch]$AllowFailure
    )

    $headers = @{ 'Content-Type' = 'application/json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    $params = @{ Uri = "$BaseUrl$Path"; Method = $Method; Headers = $headers }
    if ($null -ne $Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 12) }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        if ($AllowFailure) { return $null }
        throw
    }
}

# Formats minor units as "1,500.00" for a realistic SMS body.
function Format-Major {
    param([int]$Minor)
    $whole = [math]::Floor($Minor / 100)
    $frac = $Minor % 100
    return ('{0:N0}.{1:D2}' -f $whole, $frac)
}

Write-Host ''
Write-Host "GreenBiz demo seed -> $BaseUrl" -ForegroundColor Cyan
Write-Host ''

# --------------------------------------------------------------- account -----

Write-Host 'Account' -ForegroundColor Yellow

$session = Invoke-Api -Method POST -Path '/auth/login' -Body @{
    username = $Username
    password = $Password
} -AllowFailure

if ($session) {
    Write-Host "  Reusing existing account '$Username'."
}
else {
    $session = Invoke-Api -Method POST -Path '/auth/register' -Body @{
        fullName     = $FullName
        username     = $Username
        password     = $Password
        shopName     = $ShopName
        businessType = 'retail'
    }
    Write-Host "  Created account '$Username'."
}

$token = $session.token
$me = Invoke-Api -Method GET -Path '/auth/me' -Token $token
$shop = $me.shops[0]
if (-not $shop) { throw 'The account has no shop; cannot attach data.' }
$shopId = $shop.id

Write-Host "  User:  $($me.user.fullName) (@$($me.user.username))"
Write-Host "  Shop:  $($shop.shopName)  [$shopId]"

# -------------------------------------------------------------- inventory ----

Write-Host ''
Write-Host 'Inventory' -ForegroundColor Yellow

$catalogue = @(
    @{ productName = 'Aromatic rice 5kg'; unit = 'bag'; unitPriceMinor = 95000; stockQuantity = 24 },
    @{ productName = 'Soybean oil 1L'; unit = 'bottle'; unitPriceMinor = 21500; stockQuantity = 48 },
    @{ productName = 'Sugar (loose)'; unit = 'kg'; unitPriceMinor = 12500; stockQuantity = 60.5 },
    @{ productName = 'Lentil (masoor dal)'; unit = 'kg'; unitPriceMinor = 14500; stockQuantity = 35 },
    @{ productName = 'Tea leaf 400g'; unit = 'packet'; unitPriceMinor = 32000; stockQuantity = 18 },
    @{ productName = 'Laundry soap bar'; unit = 'piece'; unitPriceMinor = 5500; stockQuantity = 120 },
    @{ productName = 'Biscuit (family pack)'; unit = 'packet'; unitPriceMinor = 8000; stockQuantity = 3 },
    @{ productName = 'Milk powder 500g'; unit = 'packet'; unitPriceMinor = 68000; stockQuantity = 9 }
)

$existing = (Invoke-Api -Method GET -Path "/shops/$shopId/products" -Token $token).products
$existingNames = @($existing | ForEach-Object { $_.productName })

$added = 0
foreach ($item in $catalogue) {
    if ($existingNames -contains $item.productName) { continue }
    Invoke-Api -Method POST -Path "/shops/$shopId/products" -Token $token -Body $item | Out-Null
    $added++
}
Write-Host "  $($existingNames.Count) already present, $added added (total $(($existingNames.Count + $added)))."

# --------------------------------------------------------------- sms data ----

Write-Host ''
Write-Host 'Payment messages (about 3 months)' -ForegroundColor Yellow

# Day boundaries, so re-running on the same day produces identical timestamps
# and the server's dedupe index rejects every duplicate.
$midnightUtc = [DateTime]::UtcNow.Date
$customerNumbers = @('01782665484', '01712345678', '01822334455', '01933445566', '01644556677', '01755667788')
$inAmounts = @(50000, 65000, 80000, 95000, 120000, 135000, 150000, 185000, 200000, 250000)
$outAmounts = @(40000, 55000, 70000, 90000)

$messages = New-Object System.Collections.Generic.List[object]
$counter = 0

foreach ($d in 87..1) {
    $day = $midnightUtc.AddDays(-$d)

    # Money in, every third day: the shop's ordinary daily takings.
    if ($d % 3 -eq 0) {
        $counter++
        $amount = $inAmounts[$counter % $inAmounts.Count]
        $number = $customerNumbers[$counter % $customerNumbers.Count]
        $trx = 'BK{0:D7}' -f (1000000 + $counter * 37)
        $stamp = $day.AddHours(10 + ($counter % 8)).AddMinutes(($counter * 7) % 60)
        $messages.Add(@{
                sender     = '16247'
                body       = "You have received Tk $(Format-Major $amount) from $number. Fee Tk 0.00. Balance Tk $(Format-Major ($amount + 19905)). TrxID $trx at $($stamp.ToString('dd/MM/yyyy HH:mm'))"
                receivedAt = [DateTimeOffset]::new($stamp, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
            })
    }

    # Money out, every ninth day: supplier payments.
    if ($d % 9 -eq 0) {
        $counter++
        $amount = $outAmounts[$counter % $outAmounts.Count]
        $number = $customerNumbers[($counter + 2) % $customerNumbers.Count]
        $trx = 'BK{0:D7}' -f (2000000 + $counter * 41)
        $stamp = $day.AddHours(17).AddMinutes(($counter * 11) % 60)
        $messages.Add(@{
                sender     = '16247'
                body       = "You have sent Tk $(Format-Major $amount) to $number. Fee Tk 0.00. Balance Tk $(Format-Major 120000). TrxID $trx at $($stamp.ToString('dd/MM/yyyy HH:mm'))"
                receivedAt = [DateTimeOffset]::new($stamp, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
            })
    }

    # Nagad, every fifteenth day: a customer paying through the other network.
    if ($d % 15 -eq 0) {
        $counter++
        $amount = 90000 + $counter * 500
        $number = $customerNumbers[($counter + 4) % $customerNumbers.Count]
        $trx = '{0:D10}' -f (3000000000 + $counter * 137)
        $stamp = $day.AddHours(13)
        $messages.Add(@{
                sender     = '16248'
                body       = "You have received Tk $(Format-Major $amount) from $number. Your new balance is Tk $(Format-Major 250000). TrxID: $trx"
                receivedAt = [DateTimeOffset]::new($stamp, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
            })
    }

    # Rocket, every twenty-first day.
    if ($d % 21 -eq 0) {
        $counter++
        $amount = 110000
        $number = $customerNumbers[($counter + 5) % $customerNumbers.Count]
        $trx = '{0:D12}' -f (400000000000 + $counter * 211)
        $stamp = $day.AddHours(19)
        $messages.Add(@{
                sender     = '16216'
                body       = "You have received Tk $(Format-Major $amount) from $number. Reference: $trx. Your new balance: Tk $(Format-Major 300000)."
                receivedAt = [DateTimeOffset]::new($stamp, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
            })
    }
}

# One message that is deliberately NOT a payment. It proves the device-side
# filter and the server-side pre-filter both work, and it should never become a
# transaction.
$personalStamp = $midnightUtc.AddDays(-4).AddHours(21)
$messages.Add(@{
        sender     = 'PERSONAL'
        body       = 'Hey, are you open tomorrow morning? Need to pick up rice before 9.'
        receivedAt = [DateTimeOffset]::new($personalStamp, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
    })

$paymentCount = $messages.Count - 1
Write-Host "  $paymentCount payment messages + 1 personal message, spread over 87 days."

# Upload in batches, mirroring what the phone does.
$batchSize = 100
$totals = @{ inserted = 0; duplicates = 0; parsed = 0; notPayment = 0; transactionsCreated = 0; regex = 0; llm = 0 }
$score = $null

for ($i = 0; $i -lt $messages.Count; $i += $batchSize) {
    $end = [math]::Min($i + $batchSize, $messages.Count) - 1
    $batch = $messages[$i..$end]

    $response = Invoke-Api -Method POST -Path "/shops/$shopId/sms/bulk" -Token $token -Body @{ messages = $batch }
    $s = $response.summary

    $totals.inserted += [int]$s.inserted
    $totals.duplicates += [int]$s.duplicates
    $totals.parsed += [int]$s.parsed
    $totals.notPayment += [int]$s.notPayment
    $totals.transactionsCreated += [int]$s.transactionsCreated
    $totals.regex += [int]$s.bySource.regex
    $totals.llm += [int]$s.bySource.llm
    if ($null -ne $s.score) { $score = [int]$s.score }
}

Write-Host "  inserted=$($totals.inserted) duplicates=$($totals.duplicates) parsed=$($totals.parsed) notPayment=$($totals.notPayment)"
Write-Host "  transactions created=$($totals.transactionsCreated) (regex=$($totals.regex), llm=$($totals.llm))"

# --------------------------------------------------- manual transactions -----

Write-Host ''
Write-Host 'Manual entries' -ForegroundColor Yellow

$ledger = (Invoke-Api -Method GET -Path "/shops/$shopId/transactions?limit=500" -Token $token).transactions
$hasManual = @($ledger | Where-Object { $_.note -like 'Demo:*' }).Count -gt 0

if ($hasManual) {
    Write-Host '  Manual entries already present, skipping.'
}
else {
    $manual = @(
        @{ direction = 'in'; amountMinor = 450000; counterparty = 'Walk-in customer'; note = 'Demo: cash sale'; currency = 'BDT' },
        @{ direction = 'in'; amountMinor = 320000; counterparty = 'Walk-in customer'; note = 'Demo: cash sale'; currency = 'BDT' },
        @{ direction = 'in'; amountMinor = 275000; counterparty = 'School canteen'; note = 'Demo: bulk order'; currency = 'BDT' },
        @{ direction = 'out'; amountMinor = 1200000; counterparty = 'Shop landlord'; note = 'Demo: monthly rent'; currency = 'BDT' },
        @{ direction = 'out'; amountMinor = 380000; counterparty = 'Wholesale market'; note = 'Demo: restock payment'; currency = 'BDT' }
    )
    foreach ($entry in $manual) {
        Invoke-Api -Method POST -Path "/shops/$shopId/transactions" -Token $token -Body $entry | Out-Null
    }
    Write-Host "  Added $($manual.Count) manual transactions (cash sales, rent, restock)."
}

# ------------------------------------------------------------- recompute -----

$credit = Invoke-Api -Method POST -Path "/shops/$shopId/credit/recompute" -Token $token
$profile = $credit.creditProfile

$ledgerCount = (Invoke-Api -Method GET -Path "/shops/$shopId/transactions?limit=500" -Token $token).transactions.Count
$productCount = (Invoke-Api -Method GET -Path "/shops/$shopId/products" -Token $token).products.Count

# ------------------------------------------------------------------ report --

Write-Host ''
Write-Host 'Ready to test' -ForegroundColor Green
Write-Host ''
Write-Host "  API base   : $BaseUrl"
Write-Host "  Username   : $Username"
Write-Host "  Password   : $Password"
Write-Host "  Shop id    : $shopId"
Write-Host ''
Write-Host "  Products   : $productCount"
Write-Host "  Transactions: $ledgerCount"
Write-Host "  Credit score: $($profile.score)/100"
Write-Host "  Factors     : $(($profile.factors | ForEach-Object { "$($_.name)=$($_.score)" }) -join ', ')"
Write-Host "  Risk flags  : $(if ($profile.riskFlags.Count -gt 0) { $profile.riskFlags -join ', ' } else { 'none' })"
Write-Host ''
Write-Host '  Open the app against this API with:' -ForegroundColor Cyan
Write-Host "    flutter run -d android --dart-define=GREENBIZ_API_URL=$BaseUrl"
Write-Host ''
