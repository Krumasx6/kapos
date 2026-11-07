param(
    [switch]$GenerateTestBackground,
    [switch]$GenerateRemainingBackgrounds,
    [switch]$GenerateSecondBatch,
    [switch]$GenerateSecondBatchNoInit
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$secret = $env:PIXELLAB_SECRET
if ([string]::IsNullOrWhiteSpace($secret)) {
    $envPath = Join-Path $projectRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath)) { throw 'PIXELLAB_SECRET is not set and project .env was not found.' }
    $secretLine = Get-Content -LiteralPath $envPath | Where-Object { $_ -match '^PIXELLAB_SECRET=' } | Select-Object -First 1
    if ($null -eq $secretLine) { throw 'PIXELLAB_SECRET is missing from project .env.' }
    $secret = $secretLine.Substring('PIXELLAB_SECRET='.Length).Trim()
}
if ([string]::IsNullOrWhiteSpace($secret)) { throw 'PIXELLAB_SECRET is empty.' }

$headers = @{ Authorization = "Bearer $secret" }
$baseUrl = 'https://api.pixellab.ai/v2'
$style = '2D pixel art, side-on view, warm slightly desaturated palette, modern Philippine neighborhood, no characters, no text, no UI.'
$settings = [ordered]@{
    outline = 'selective outline'
    shading = 'medium shading'
    detail = 'medium detail'
    view = 'side'
}

function Get-PixelLabBalance {
    try {
        Invoke-RestMethod -Method Get -Uri "$baseUrl/balance" -Headers $headers -TimeoutSec 60
    }
    catch {
        throw 'PixelLab balance request failed. No image request was made after this check.'
    }
}

function Get-BalanceSummary($balance) {
    $usd = $null
    $generations = $null
    if ($null -ne $balance.credits) { $usd = $balance.credits.usd }
    if ($null -ne $balance.subscription) { $generations = $balance.subscription.generations }
    [pscustomobject]@{ credits_usd = $usd; subscription_generations = $generations }
}

function Save-ManifestAsset([string]$assetId) {
    $manifestPath = Join-Path $projectRoot 'assets/manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $placeholder = '#3A4249'
    if ($manifest.assets.PSObject.Properties.Name -contains $assetId) {
        $placeholder = [string]$manifest.assets.$assetId.placeholder_color
    }
    $asset = [pscustomobject]@{
        kind = 'background'
        label_key = 'UI-C1-ASSET-BG'
        placeholder_color = $placeholder
        path = "res://assets/backgrounds/$assetId.png"
    }
    $manifest.assets | Add-Member -NotePropertyName $assetId -NotePropertyValue $asset -Force

    $stageMappings = @{
        magsino_house_dawn = @('magsino_house_dawn')
        magsino_house_night = @('magsino_house_night')
        tambayan = @('rider_lounge')
        cargo_hub_bay4 = @('bay4_delivery', 'bay4_day', 'bay4_afterhours')
        maniquis_back_door = @('susan_store')
        dumalagan_house = @('dumalagan_home_dawn', 'dumalagan_home_night')
        river_road_night = @('river_road_night')
        salvador_gate = @('salvador_gate')
        salvador_dining = @('salvador_dinner')
        siis_gym = @('siis_science_fair')
        dike_steps_night = @('dike_steps_night')
        barangay_hall = @('barangay_hall')
        sidh_pharmacy = @('sidh_pharmacy')
        sidh_ward = @('sidh_ward')
        city_hall_corridor = @('city_hall_corridor')
        cargo_hub_bay7 = @('bay7_afterhours')
        dado_office = @('dado_office')
        tito_boy_garage = @('union_garage')
        tanggol_manggagawa_office = @('tanggol_manggagawa_office')
        valdez_drawing_room = @('valdez_drawing_room')
        valdez_study_corridor = @('valdez_corridor')
        tita_baby_house = @('tita_baby_home')
        tabing_ilog_flooded = @('tabing_ilog_flooded')
        magsino_loft_flooded = @('magsino_loft_flooded')
        pumping_station_night = @('pumping_station_night')
        creek_overflow = @('creek_overflow')
        siis_gym_evacuation = @('siis_gym_evacuation')
        collapsed_dike = @('collapsed_dike')
        vlw_gate_picket = @('vlw_gate_picket')
        city_council_hall = @('city_council_hall')
        river_dawn_epilogue = @('river_dawn_epilogue')
    }
    foreach ($stageId in $stageMappings[$assetId]) {
        if ($manifest.stages.PSObject.Properties.Name -contains $stageId) {
            $manifest.stages.$stageId.background = $assetId
        }
        else {
            $manifest.stages | Add-Member -NotePropertyName $stageId -NotePropertyValue ([pscustomobject]@{
                background = $assetId
                lighting = 'test_neutral'
                placeholder_color = $placeholder
                transition = 'cut'
            }) -Force
        }
    }
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding utf8
}

function Save-PromptRecord($record) {
    $path = Join-Path $projectRoot 'tools/art_prompts.json'
    $records = @()
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($null -ne $existing) { $records = @($existing) }
    }
    $records = @($records | Where-Object { $_.manifest_id -ne $record.manifest_id }) + @($record)
    $records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
}

function Add-LedgerEntry([string]$assetId, [string]$status, $before, $after, $used, $usd) {
    $ledgerPath = Join-Path $projectRoot 'tools/art_ledger.txt'
    $date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $usedText = if ($null -eq $used) { 'unverified' } else { $used }
    $usdText = if ($null -eq $usd) { 'not_returned' } else { $usd }
    "$date $assetId status=$status generations_used=$usedText usage_usd=$usdText generations_before=$($before.subscription_generations) generations_after=$($after.subscription_generations)" |
        Add-Content -LiteralPath $ledgerPath -Encoding utf8
}

function Invoke-BackgroundGeneration([string]$assetId, [string]$scene, [int]$seed, [string]$initReference = '', [bool]$overwriteExisting = $false) {
    $outputDir = Join-Path $projectRoot 'assets/backgrounds'
    $outputPath = Join-Path $outputDir "$assetId.png"
    if ((Test-Path -LiteralPath $outputPath) -and -not $overwriteExisting) { throw "Refusing duplicate image request for $assetId because the output file already exists." }

    $before = Get-PixelLabBalance
    $beforeSummary = Get-BalanceSummary $before
    if ($null -eq $beforeSummary.subscription_generations) {
        throw 'PixelLab balance did not include a subscription generation count; stopping before image request.'
    }
    if ([double]$beforeSummary.subscription_generations -lt 20) {
        throw 'Remaining subscription generations are below 20; stopping before image request.'
    }

    $prompt = "$style $scene"
    $payload = [ordered]@{
        description = $prompt
        image_size = [ordered]@{ width = 320; height = 180 }
        outline = $settings.outline
        shading = $settings.shading
        detail = $settings.detail
        view = $settings.view
        seed = $seed
    }
    if (-not [string]::IsNullOrWhiteSpace($initReference)) {
        $initPath = Join-Path $projectRoot "assets/backgrounds/$initReference.png"
        if (-not (Test-Path -LiteralPath $initPath)) { throw "Init image reference is missing for $assetId." }
        $initData = [Convert]::ToBase64String([IO.File]::ReadAllBytes($initPath))
        $payload.init_image = [ordered]@{ type = 'base64'; base64 = "data:image/png;base64,$initData" }
        $payload.init_image_strength = 300
    }
    $jsonBody = $payload | ConvertTo-Json -Depth 8
    try {
        $job = Invoke-RestMethod -Method Post -Uri "$baseUrl/create-image-pixflux-background" -Headers $headers -ContentType 'application/json' -Body $jsonBody -TimeoutSec 120
    }
    catch {
        $afterFailure = Get-PixelLabBalance
        $afterFailureSummary = Get-BalanceSummary $afterFailure
        Add-LedgerEntry $assetId 'submission_failed' $beforeSummary $afterFailureSummary $null $null
        throw "PixelLab submission failed for $assetId. No automatic retry was attempted."
    }
    if ([string]::IsNullOrWhiteSpace($job.background_job_id)) { throw "PixelLab returned no usable job ID for $assetId; no retry was attempted." }

    $jobResult = $null
    while ($true) {
        Start-Sleep -Seconds 7
        try {
            $jobResult = Invoke-RestMethod -Method Get -Uri "$baseUrl/background-jobs/$($job.background_job_id)" -Headers $headers -TimeoutSec 60
        }
        catch {
            $afterStatusFailure = Get-PixelLabBalance
            Add-LedgerEntry $assetId 'status_lookup_failed' $beforeSummary (Get-BalanceSummary $afterStatusFailure) $null $null
            throw "PixelLab status lookup failed for $assetId. The submitted job was not resubmitted."
        }
        if ($jobResult.status -eq 'completed') { break }
        if ($jobResult.status -eq 'failed') {
            $afterFailed = Get-PixelLabBalance
            Add-LedgerEntry $assetId 'generation_failed' $beforeSummary (Get-BalanceSummary $afterFailed) $null $null
            throw "PixelLab marked $assetId failed. No retry was attempted."
        }
    }

    $after = Get-PixelLabBalance
    $afterSummary = Get-BalanceSummary $after
    $usage = $jobResult.usage
    if ($null -eq $usage -or $null -eq $usage.type) { $usage = $job.usage }
    $used = $null
    if ($null -ne $usage -and $usage.type -eq 'generations') { $used = [double]$usage.generations }
    if ($null -ne $beforeSummary.subscription_generations -and $null -ne $afterSummary.subscription_generations) {
        $balanceDelta = [double]$beforeSummary.subscription_generations - [double]$afterSummary.subscription_generations
        if ($null -eq $used -or $balanceDelta -gt $used) { $used = $balanceDelta }
    }
    $usageUsd = $null
    if ($null -ne $usage -and $usage.type -eq 'usd') { $usageUsd = $usage.usd }
    $imageBase64 = [string]$jobResult.last_response.image.base64
    if ([string]::IsNullOrWhiteSpace($imageBase64)) {
        Add-LedgerEntry $assetId 'completed_without_image' $beforeSummary $afterSummary $used $usageUsd
        throw "Completed job $assetId had no image data. No retry was attempted."
    }
    if ($imageBase64 -match '^data:image/[^;]+;base64,') { $imageBase64 = $imageBase64 -replace '^data:image/[^;]+;base64,', '' }
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    [IO.File]::WriteAllBytes($outputPath, [Convert]::FromBase64String($imageBase64))
    Add-LedgerEntry $assetId 'completed' $beforeSummary $afterSummary $used $usageUsd

    $promptRecord = [ordered]@{
        manifest_id = $assetId
        prompt = $prompt
        image_size = [ordered]@{ width = 320; height = 180 }
        settings = $settings
        seed = $seed
        endpoint = 'POST /v2/create-image-pixflux-background'
    }
    if (-not [string]::IsNullOrWhiteSpace($initReference)) {
        $promptRecord.init_image_reference = $initReference
        $promptRecord.init_image_strength = 300
    }
    Save-PromptRecord $promptRecord
    Save-ManifestAsset $assetId

    [pscustomobject]@{
        asset = $assetId
        image_path = $outputPath
        generations_used = $used
        usage_usd = $usageUsd
        generations_before = $beforeSummary.subscription_generations
        generations_after = $afterSummary.subscription_generations
    }

    if ($null -ne $used -and [double]$used -gt 1) {
        throw "The $assetId call used more than 1 generation; stopping all further generation."
    }
    if ([double]$afterSummary.subscription_generations -lt 20) {
        throw 'Remaining subscription generations are below 20; stopping all further generation.'
    }
    if ([double]$used -ne 1) {
        throw "Could not verify exactly 1 generation for $assetId; stopping all further generation."
    }
}

$modeCount = 0
if ($GenerateTestBackground.IsPresent) { $modeCount++ }
if ($GenerateRemainingBackgrounds.IsPresent) { $modeCount++ }
if ($GenerateSecondBatch.IsPresent) { $modeCount++ }
if ($GenerateSecondBatchNoInit.IsPresent) { $modeCount++ }
if ($modeCount -gt 1) { throw 'Choose only one generation mode.' }
if ($GenerateTestBackground) { throw 'The test background has already been generated; this mode will not run again.' }
if ($GenerateRemainingBackgrounds) {
    $backgrounds = @(
    [pscustomobject]@{ id = 'magsino_house_night'; scene = 'same house at night, one dim bulb'; seed = 83620412 }
    [pscustomobject]@{ id = 'tambayan'; scene = "delivery riders' lounge, plastic chairs, broken fan, TV on a wall, warehouse bay visible through a doorway"; seed = 83620413 }
    [pscustomobject]@{ id = 'cargo_hub_bay4'; scene = 'corrugated steel loading dock with a rolling shutter, pallets, office window, floodlight'; seed = 83620414 }
    [pscustomobject]@{ id = 'maniquis_back_door'; scene = 'back door of a hardware store, stacked cement bags, a single bulb, night'; seed = 83620415 }
    [pscustomobject]@{ id = 'dumalagan_house'; scene = 'small two-room house interior, brownout dark, a wheelchair corner, a sofa'; seed = 83620416 }
    [pscustomobject]@{ id = 'river_road_night'; scene = 'warehouse-lined river road at night beside a yellow pumping station'; seed = 83620417 }
    [pscustomobject]@{ id = 'salvador_gate'; scene = 'two-story rented house with a gate that does not close, a creek beside it'; seed = 83620418 }
    [pscustomobject]@{ id = 'salvador_dining'; scene = 'crowded dining table made for six, nine plates, a ceiling lamp'; seed = 83620419 }
    [pscustomobject]@{ id = 'siis_gym'; scene = 'school gymnasium interior with a stage, basketball hoops, fluorescent lights'; seed = 83620420 }
    )
    foreach ($background in $backgrounds) {
        Invoke-BackgroundGeneration $background.id $background.scene $background.seed
    }
    return
}
if ($GenerateSecondBatch) {
    $initId = 'magsino_house_dawn'
    $backgrounds = @(
    [pscustomobject]@{ id = 'dike_steps_night'; scene = 'back steps of a hollow-block house facing a tall concrete dike wall at night, a wet dark stain, one street lamp'; seed = 83620421 }
    [pscustomobject]@{ id = 'barangay_hall'; scene = 'small barangay hall interior, a plastic chair, a desk with a lamp, a tarpaulin on the wall'; seed = 83620422 }
    [pscustomobject]@{ id = 'sidh_pharmacy'; scene = 'public hospital pharmacy window with a queue line painted on the floor, fluorescent light, a plastic bench'; seed = 83620423 }
    [pscustomobject]@{ id = 'sidh_ward'; scene = 'crowded public hospital ward, steel beds, a drip stand, window light'; seed = 83620424 }
    [pscustomobject]@{ id = 'city_hall_corridor'; scene = "crowded city hall hallway, a large smiling politician's tarpaulin, plastic chairs"; seed = 83620425 }
    [pscustomobject]@{ id = 'cargo_hub_bay7'; scene = 'warehouse bay with steel drums stacked beside cardboard relief boxes, one overhead light'; seed = 83620426 }
    [pscustomobject]@{ id = 'dado_office'; scene = 'small warehouse office with a window onto the loading floor, a metal desk, a clipboard'; seed = 83620427 }
    [pscustomobject]@{ id = 'tito_boy_garage'; scene = 'a garage with plastic chairs set out in rows, a laptop on crates, a forklift in the corner'; seed = 83620428 }
    [pscustomobject]@{ id = 'tanggol_manggagawa_office'; scene = 'second-floor legal aid office, box fan, stacked files, an old calendar'; seed = 83620429 }
    [pscustomobject]@{ id = 'valdez_drawing_room'; scene = 'grand drawing room with a piano nobody plays, polished floor, tall windows'; seed = 83620430 }
    [pscustomobject]@{ id = 'valdez_study_corridor'; scene = 'quiet corridor outside a closed study door, a dusting cloth on a chair, warm lamp'; seed = 83620431 }
    [pscustomobject]@{ id = 'tita_baby_house'; scene = 'small upland house, plain, a spare mattress on the floor, a window with trees'; seed = 83620432 }
    [pscustomobject]@{ id = 'tabing_ilog_flooded'; scene = 'flooded street at night, rooftops above brown water, rain, one roof with a small light'; seed = 83620433 }
    [pscustomobject]@{ id = 'magsino_loft_flooded'; scene = 'a small loft room with water at the floor, a bed, a cupboard, a dim flashlight beam'; seed = 83620434 }
    [pscustomobject]@{ id = 'pumping_station_night'; scene = 'yellow pump house at night beside a river, dark windows, rain'; seed = 83620435 }
    [pscustomobject]@{ id = 'creek_overflow'; scene = 'a creek overflowing a gate, a two-story house, rain at night'; seed = 83620436 }
    [pscustomobject]@{ id = 'siis_gym_evacuation'; scene = 'school gymnasium filled with cots and tarpaulin, a kitchen table, fluorescent lights'; seed = 83620437 }
    [pscustomobject]@{ id = 'collapsed_dike'; scene = 'forty metres of collapsed dike wall into brown water, mud, a floating tarpaulin, daylight'; seed = 83620438 }
    [pscustomobject]@{ id = 'vlw_gate_picket'; scene = 'warehouse gate in daylight with a hand-painted protest banner, yellow tape'; seed = 83620439 }
    [pscustomobject]@{ id = 'city_council_hall'; scene = 'council session hall with a raised panel desk, rows of benches, a camera tripod'; seed = 83620440 }
    [pscustomobject]@{ id = 'river_dawn_epilogue'; scene = 'the same river at dawn, a shorter imperfect new wall, calm water'; seed = 83620441 }
    )
    foreach ($background in $backgrounds) {
        Invoke-BackgroundGeneration $background.id $background.scene $background.seed $initId
    }
    return
}
if (-not $GenerateSecondBatchNoInit) { throw 'Pass -GenerateSecondBatchNoInit to regenerate the 21 backgrounds without init_image.' }

$backgrounds = @(
    [pscustomobject]@{ id = 'dike_steps_night'; scene = 'back steps of a hollow-block house facing a tall concrete dike wall at night, a wet dark stain, one street lamp'; seed = 83620442 }
    [pscustomobject]@{ id = 'barangay_hall'; scene = 'small barangay hall interior, a plastic chair, a desk with a lamp, a tarpaulin on the wall'; seed = 83620443 }
    [pscustomobject]@{ id = 'sidh_pharmacy'; scene = 'public hospital pharmacy window with a queue line painted on the floor, fluorescent light, a plastic bench'; seed = 83620444 }
    [pscustomobject]@{ id = 'sidh_ward'; scene = 'crowded public hospital ward, steel beds, a drip stand, window light'; seed = 83620445 }
    [pscustomobject]@{ id = 'city_hall_corridor'; scene = "crowded city hall hallway, a large smiling politician's tarpaulin, plastic chairs"; seed = 83620446 }
    [pscustomobject]@{ id = 'cargo_hub_bay7'; scene = 'warehouse bay with steel drums stacked beside cardboard relief boxes, one overhead light'; seed = 83620447 }
    [pscustomobject]@{ id = 'dado_office'; scene = 'small warehouse office with a window onto the loading floor, a metal desk, a clipboard'; seed = 83620448 }
    [pscustomobject]@{ id = 'tito_boy_garage'; scene = 'a garage with plastic chairs set out in rows, a laptop on crates, a forklift in the corner'; seed = 83620449 }
    [pscustomobject]@{ id = 'tanggol_manggagawa_office'; scene = 'second-floor legal aid office, box fan, stacked files, an old calendar'; seed = 83620450 }
    [pscustomobject]@{ id = 'valdez_drawing_room'; scene = 'grand drawing room with a piano nobody plays, polished floor, tall windows'; seed = 83620451 }
    [pscustomobject]@{ id = 'valdez_study_corridor'; scene = 'quiet corridor outside a closed study door, a dusting cloth on a chair, warm lamp'; seed = 83620452 }
    [pscustomobject]@{ id = 'tita_baby_house'; scene = 'small upland house, plain, a spare mattress on the floor, a window with trees'; seed = 83620453 }
    [pscustomobject]@{ id = 'tabing_ilog_flooded'; scene = 'flooded street at night, rooftops above brown water, rain, one roof with a small light'; seed = 83620454 }
    [pscustomobject]@{ id = 'magsino_loft_flooded'; scene = 'a small loft room with water at the floor, a bed, a cupboard, a dim flashlight beam'; seed = 83620455 }
    [pscustomobject]@{ id = 'pumping_station_night'; scene = 'yellow pump house at night beside a river, dark windows, rain'; seed = 83620456 }
    [pscustomobject]@{ id = 'creek_overflow'; scene = 'a creek overflowing a gate, a two-story house, rain at night'; seed = 83620457 }
    [pscustomobject]@{ id = 'siis_gym_evacuation'; scene = 'school gymnasium filled with cots and tarpaulin, a kitchen table, fluorescent lights'; seed = 83620458 }
    [pscustomobject]@{ id = 'collapsed_dike'; scene = 'forty metres of collapsed dike wall into brown water, mud, a floating tarpaulin, daylight'; seed = 83620459 }
    [pscustomobject]@{ id = 'vlw_gate_picket'; scene = 'warehouse gate in daylight with a hand-painted protest banner, yellow tape'; seed = 83620460 }
    [pscustomobject]@{ id = 'city_council_hall'; scene = 'council session hall with a raised panel desk, rows of benches, a camera tripod'; seed = 83620461 }
    [pscustomobject]@{ id = 'river_dawn_epilogue'; scene = 'the same river at dawn, a shorter imperfect new wall, calm water'; seed = 83620462 }
)
foreach ($background in $backgrounds) {
    Invoke-BackgroundGeneration $background.id $background.scene $background.seed '' $true
}

