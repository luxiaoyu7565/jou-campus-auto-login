[CmdletBinding()]
param([switch]$Setup,[switch]$Background,[switch]$Once,[switch]$Uninstall,[switch]$Diagnose,[switch]$UiTest,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
$script:EntryPath=$PSCommandPath
$script:StateDir=Join-Path $env:LOCALAPPDATA 'JOUCampusAutoLogin'
$script:ConfigPath=Join-Path $StateDir 'config.json'
$script:LogPath=Join-Path $StateDir 'login.log'
$script:StatusPath=Join-Path $StateDir 'status.txt'
$script:TaskName='JOU-Campus-AutoLogin'
$script:RunKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:Root='http://210.28.39.250/'
$script:Api='http://210.28.39.250:803/eportal/portal/'
$script:CarrierNames=@('中国联通','中国移动','中国电信','校园网（仅校内资源）')
$script:CarrierValues=@('@unicom','@cmcc','@telecom','')

function Write-Status([string]$Message) {
    try {
        [void][IO.Directory]::CreateDirectory($StateDir)
        [IO.File]::WriteAllText($StatusPath,$Message,[Text.Encoding]::UTF8)
        if((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 262144){Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force}
        Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$Message) -Encoding UTF8
    } catch { }
}
function Read-Config {
    if(Test-Path $ConfigPath){return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json}
    return $null
}
function Save-Config([string]$Account,[string]$Password,[string]$Carrier) {
    $previous=Read-Config
    if($Password.Length -eq 0){
        if(-not $previous.EncryptedPassword -or $previous.Account -ne $Account.Trim()){throw '首次设置或更换账号时，请输入密码。'}
        $encrypted=$previous.EncryptedPassword
    } else {$encrypted=ConvertFrom-SecureString (ConvertTo-SecureString $Password -AsPlainText -Force)}
    [void][IO.Directory]::CreateDirectory($StateDir)
    [ordered]@{Version=2;Account=$Account.Trim();EncryptedPassword=$encrypted;Carrier=$Carrier} |
        ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}
function Get-Password($Config) {
    $secure=ConvertTo-SecureString $Config.EncryptedPassword
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try{return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
    finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr);$secure.Dispose()}
}
function Set-Autostart([bool]$Enabled) {
    $scheduler=New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder=$scheduler.GetFolder('\')
    if($Enabled){
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $task=$scheduler.NewTask(0)
        $task.RegistrationInfo.Description='江苏海洋大学校园网自动登录：用户登录后立即启动。'
        $task.Principal.UserId=$userSid
        $task.Principal.LogonType=3 # Current interactive user; no Windows password stored.
        $task.Principal.RunLevel=0
        $trigger=$task.Triggers.Create(9) # User logon.
        $trigger.UserId=$userSid
        $trigger.Delay='PT0S'
        $action=$task.Actions.Create(0)
        $action.Path=$exe
        $action.Arguments='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$EntryPath+'" -Background'
        $action.WorkingDirectory=Split-Path -Parent $EntryPath
        $task.Settings.Enabled=$true
        $task.Settings.StartWhenAvailable=$true
        $task.Settings.DisallowStartIfOnBatteries=$false
        $task.Settings.StopIfGoingOnBatteries=$false
        $task.Settings.RunOnlyIfNetworkAvailable=$false
        $task.Settings.RunOnlyIfIdle=$false
        $task.Settings.ExecutionTimeLimit='PT0S'
        $task.Settings.MultipleInstances=2
        $task.Settings.Priority=5
        $task.Settings.RestartInterval='PT1M'
        $task.Settings.RestartCount=3
        [void]$folder.RegisterTaskDefinition($TaskName,$task,6,$userSid,$null,3,$null)
        # Remove the delayed Run entry only after successful task registration.
        Remove-ItemProperty -Path $RunKey -Name $TaskName -ErrorAction SilentlyContinue
    } else {
        foreach($registered in $folder.GetTasks(1)){
            if($registered.Name -eq $TaskName){$registered.Enabled=$false}
        }
        Remove-ItemProperty -Path $RunKey -Name $TaskName -ErrorAction SilentlyContinue
    }
}
function Get-WebText([string]$Url) {
    $uri=[uri]$Url
    if($uri.Host -ne '210.28.39.250' -or $uri.Port -notin @(80,803) -or $uri.Scheme -ne 'http'){throw '认证地址不符合学校地址，已停止。'}
    $request=[Net.HttpWebRequest]::Create($uri)
    $request.Proxy=$null; $request.AllowAutoRedirect=$false
    $request.Timeout=8000; $request.ReadWriteTimeout=8000
    $request.UserAgent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) JOUAutoLogin/2.0'
    try {
        $response=$request.GetResponse()
        try {
            if([int]$response.StatusCode -ne 200){throw 'Unexpected status'}
            $encoding=[Text.Encoding]::UTF8
            if($response.CharacterSet -match 'gb'){$encoding=[Text.Encoding]::GetEncoding(936)}
            $reader=New-Object IO.StreamReader($response.GetResponseStream(),$encoding)
            try{return $reader.ReadToEnd()}finally{$reader.Dispose()}
        }finally{$response.Dispose()}
    }catch{throw '校园网服务器暂时不可达或响应异常，请确认已连接学校网络。'}
}
function Convert-Query($Data) {
    return (($Data.GetEnumerator() | ForEach-Object {
        [uri]::EscapeDataString([string]$_.Key)+'='+[uri]::EscapeDataString([string]$_.Value)
    }) -join '&')
}
function Convert-PortalValue([string]$Value,[string]$IP) {
    $key=0
    foreach($ch in $IP.ToCharArray()){$key=$key -bxor [int]$ch}
    $builder=New-Object Text.StringBuilder
    foreach($ch in $Value.ToCharArray()){[void]$builder.Append((([int]$ch -bxor $key).ToString('x2')))}
    return $builder.ToString()
}
function Read-Jsonp([string]$Text) {
    $match=[regex]::Match($Text,'^\s*(?:[A-Za-z_][\w]*\()?\s*(\{.*\})\s*\)?;?\s*$','Singleline')
    if(-not $match.Success){throw '学校认证接口返回了无法识别的页面。'}
    try{return $match.Groups[1].Value | ConvertFrom-Json}catch{throw '认证响应格式发生变化。'}
}
function Invoke-Portal([string]$Action,$Data,[string]$IP,[bool]$Encrypt=$true) {
    if($Action -notin @('page/loadConfig','online_list','login')){throw '不支持的认证操作。'}
    $values=[ordered]@{}
    foreach($item in $Data.GetEnumerator()){$values[$item.Key]=[string]$item.Value}
    $values.callback='dr1001'; $values.jsVersion='4.X'
    if($Encrypt){
        foreach($key in @($values.Keys)){$values[$key]=Convert-PortalValue $values[$key] $IP}
        $values.encrypt='1'
    }
    return Read-Jsonp (Get-WebText ($Api+$Action+'?'+(Convert-Query $values)))
}
function Get-Context {
    $html=Get-WebText $Root
    if($html -notmatch 'Dr.COMWebLoginID_'){throw '尚未识别到学校认证页面。'}
    $ip=[regex]::Match($html,"v46ip='([^']+)'").Groups[1].Value.Trim()
    $localIps=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | ForEach-Object {
        $_.GetIPProperties().UnicastAddresses | ForEach-Object {$_.Address.ToString()}
    })
    if($ip -notin $localIps){throw '尚未连接到可认证的校园网，等待网络连接。'}
    $mac=[regex]::Match($html,'ss4="([^"]+)"').Groups[1].Value.Trim()
    if(-not $mac){$mac='000000000000'}
    $vlan=[regex]::Match($html,'vlanid="([^"]+)"').Groups[1].Value.Trim()
    $encodedIP=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ip))
    $settings=Invoke-Portal 'page/loadConfig' ([ordered]@{
        program_index='';wlan_vlan_id=$vlan;wlan_user_ip=$encodedIP;wlan_user_ipv6=''
        wlan_user_ssid='';wlan_user_areaid='';wlan_ac_ip='';wlan_ap_mac='000000000000';gw_id='000000000000'
    }) $ip $false
    if($settings.code -ne 1 -or $settings.data.login_method -ne 1 -or $settings.data.enable_r3 -ne 0){throw '学校认证方式已变化，请更新工具。'}
    return [pscustomobject]@{IP=$ip;Mac=$mac;Vlan=$vlan;Settings=$settings.data}
}
function Get-Online($Context) {
    $encodedIP=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Context.IP))
    $response=Invoke-Portal 'online_list' ([ordered]@{
        user_account='';user_password='';wlan_user_mac=$Context.Mac.ToUpper();wlan_user_ip=$encodedIP;wlan_user_ipv6=''
    }) $Context.IP
    if([string]$response.result -notin @('0','1')){throw '无法判断校园网在线状态，暂不尝试登录。'}
    return ([string]$response.result -eq '1')
}
function Get-LoginAccount([string]$Account,[string]$Carrier,[bool]$Prefix) {
    if($Carrier -notin $CarrierValues){throw '请重新选择运营商。'}
    $name=$Account.Trim() -replace '^,[01],','' -replace '@(unicom|cmcc|telecom)$',''
    if($Prefix){$name=',0,'+$name}
    return $name+$Carrier
}
function Invoke-Login($Config,$Context) {
    $account=Get-LoginAccount $Config.Account $Config.Carrier ($Context.Settings.account_prefix -eq 1)
    $password=Get-Password $Config
    try {
        $base64=$Context.Settings.no_filter_accandpwd -eq 1
        if($base64){
            $account=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($account))
            $password=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password))
        }
        $data=[ordered]@{
            login_method='1';is_base64encode=[int]$base64;user_account=$account;user_password=$password
            wlan_user_ip=$Context.IP;wlan_user_ipv6='';wlan_user_mac=$Context.Mac;wlan_vlan_id=$Context.Vlan
            wlan_ac_ip='';wlan_ac_name='';authex_enable='';terminal_type='1';lang='zh-cn'
            user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64)';enable_r3='0';mac_type='0'
            rcn=$Context.Settings.rcn;operate='portal_login';business_type='1'
        }
        $response=Invoke-Portal 'login' $data $Context.IP
        if([string]$response.result -notin @('1','ok')){return $false}
        Start-Sleep -Seconds 2
        return Get-Online $Context
    }finally{$password=$null;$data=$null}
}
function Start-Worker {
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    [void](Start-Process -FilePath $exe -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$EntryPath+'" -Background') -WindowStyle Hidden -PassThru)
}
function Show-Setup {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $existing=$null
    if(-not $UiTest){$existing=Read-Config}
    $form=New-Object Windows.Forms.Form
    $form.Text='校园网自动登录 · 联通适配版 2.1'
    $form.AutoScaleMode='Dpi'
    $form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96)
    $form.ClientSize=New-Object Drawing.Size(700,500)
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',12)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
    function Add-Label([string]$Text,[int]$Y,[int]$Height=32,[int]$Width=630) {
        $label=New-Object Windows.Forms.Label
        $label.Text=$Text;$label.Location=New-Object Drawing.Point(32,$Y);$label.Size=New-Object Drawing.Size($Width,$Height)
        $form.Controls.Add($label)
    }
    Add-Label '江苏海洋大学 · 选择运营商后自动认证' 28
    Add-Label '账号' 94 32 90
    $account=New-Object Windows.Forms.TextBox
    $account.SetBounds(145,90,520,36);if($existing){$account.Text=$existing.Account};$form.Controls.Add($account)
    Add-Label '密码' 158 32 90
    $password=New-Object Windows.Forms.TextBox
    $password.SetBounds(145,154,520,36);$password.UseSystemPasswordChar=$true;$form.Controls.Add($password)
    Add-Label '运营商' 222 32 90
    $carrier=New-Object Windows.Forms.ComboBox
    $carrier.SetBounds(145,218,520,36);$carrier.DropDownStyle='DropDownList'
    $carrier.Items.AddRange([object[]]$CarrierNames);$carrier.SelectedIndex=0
    if($existing.Version -eq 2){$index=[array]::IndexOf($CarrierValues,[string]$existing.Carrier);if($index -ge 0){$carrier.SelectedIndex=$index}}
    $form.Controls.Add($carrier)
    Add-Label '已保存密码时可留空；账号填写方式与学校网页相同。' 280
    $startup=New-Object Windows.Forms.CheckBox
    $startup.Text='登录 Windows 后自动运行';$startup.SetBounds(32,325,550,32);$startup.Checked=$true;$form.Controls.Add($startup)
    $status=New-Object Windows.Forms.Label
    $status.SetBounds(32,374,630,54);$status.Text='默认已选中国联通，点击保存后生效。';$form.Controls.Add($status)
    $save=New-Object Windows.Forms.Button
    $save.Text='保存并启用';$save.SetBounds(455,438,210,44);$form.Controls.Add($save)
    $save.Add_Click({
        try {
            if([string]::IsNullOrWhiteSpace($account.Text)){throw '请输入校园网账号。'}
            Save-Config $account.Text $password.Text $CarrierValues[$carrier.SelectedIndex]
            $password.Clear();$startupNotice=''
            try{Set-Autostart $startup.Checked}catch{$startupNotice='（开机启动设置失败，但本次可运行）'}
            Start-Worker
            $status.Text='已保存，后台已启用。'+$startupNotice
        }catch{$status.Text=$_.Exception.Message}
    })
    $timer=New-Object Windows.Forms.Timer
    $timer.Interval=3000
    $timer.Add_Tick({if(Test-Path $StatusPath){try{$status.Text=[IO.File]::ReadAllText($StatusPath,[Text.Encoding]::UTF8)}catch{}}})
    if($UiTest){
        $form.Add_Shown({
            if($carrier.SelectedItem -ne '中国联通' -or -not $password.UseSystemPasswordChar){throw 'UI smoke test failed'}
            foreach($field in @($account,$password,$carrier)){
                if($field.Width -lt 500 -or $field.Right -gt $form.ClientSize.Width){throw 'Input field clipped'}
                foreach($label in $form.Controls){
                    if($label -is [Windows.Forms.Label] -and $label.Bounds.IntersectsWith($field.Bounds)){throw 'Label overlaps input'}
                }
            }
            Write-Output 'UI_CREATED: account, masked password, carrier=China Unicom, save button'
            $form.Close()
        })
    }else{$timer.Start()}
    try{[void]$form.ShowDialog()}finally{$timer.Dispose();$form.Dispose()}
}

if($LibraryOnly){return}
try {
    if($Diagnose){
        $context=Get-Context
        'Portal configuration: supported';'Campus online: '+(Get-Online $context);'Carrier mapping: China Unicom -> @unicom'
        exit 0
    }
    if($Uninstall){Set-Autostart $false;Write-Status '已关闭开机启动。';exit 0}
    if(-not $Background -and -not $Once){Show-Setup;exit 0}
    $mutex=New-Object Threading.Mutex($false,'Local\JOUCampusAutoLogin-v2')
    $owned=$false
    try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){$mutex.Dispose();exit 0}
    try {
        Write-Status '后台已启动，正在检查校园网。'
        $failures=0;$lastConfig='';$lastStatus=''
        do {
            $delay=30
            try {
                $stamp=(Get-Item $ConfigPath).LastWriteTimeUtc.Ticks
                if($stamp -ne $lastConfig){$lastConfig=$stamp;$failures=0}
                $config=Read-Config
                if($config.Version -ne 2){throw '请打开设置窗口，选择中国联通后保存。'}
                $context=Get-Context
                if(Get-Online $context){$message='校园网已认证，正在后台守候。';$failures=0}
                elseif($failures -ge 3){$message='认证失败三次，已暂停重试。请检查账号、密码和运营商后重新保存。';$delay=60}
                elseif(Invoke-Login $config $context){$message='已自动登录校园网。';$failures=0}
                else{$failures++;$message='认证未成功，请检查账号、密码和运营商；五分钟后重试。';$delay=300}
            }catch{
                $message='暂未就绪：'+$_.Exception.Message
                if($message -match '校园网服务器暂时不可达|尚未连接到可认证的校园网'){$delay=5}
                else{$delay=30}
            }
            if($message -ne $lastStatus){Write-Status $message;$lastStatus=$message}
            if($Once){break}
            Start-Sleep -Seconds $delay
        }while($true)
    }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}catch{
    Write-Status '工具启动失败，请重新打开设置窗口。'
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
