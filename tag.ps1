param(
    [Parameter(Mandatory = $true)]
    [string]$version,
    [switch]$delete,
    [switch]$push
)
function TagExistsLocal($tagName) {
    return git tag | Where-Object { $_ -eq $tagName }
}

function TagExistsRemote($tagName) {
    return git ls-remote --tags origin | Select-String "refs/tags/$tagName"
}

function CreateSignedTag($v) {
    $tagName = "$v"
    $tagMessage = "Release version $v"

    if (TagExistsLocal $tagName) {
        Write-Warning "⚠️ The local tag '$tagName' already exists. Use -delete to remove it or provide a new version."
        return $false
    }

    try {
        git tag -s $tagName -m $tagMessage
        Write-Host "✅ Successfully created and signed tag '$tagName'."
        return $true
    } catch {
        Write-Warning "⚠️ Error signing tag '$tagName'."
        $choice = Read-Host "Do you wanna (r)etry or (f)orce creation without signature? [r/f]"
        if ($choice -match '^[rR]$') {
            $newVersion = Read-Host "Provide a new version (format X.X.X ou X.X.X.X)"
             
            return CreateSignedTag $newVersion
             
        } elseif ($choice -match '^[fF]$') {
            git tag $tagName -m $tagMessage
            Write-Host "⚠️ Tag '$tagName' created without signature."
            return $true
        } else {
            Write-Error "❌ Invalid option. Quitting"
            exit 1
        }
    }
}

function PushTag($v) {
    $tagName = "$v"

    if (TagExistsRemote $tagName) {
        Write-Warning "⚠️ The remote tag '$tagName' already exists."
        return $false
    }

    try {
        git push origin $tagName
        Write-Host "🚀 Sucessfully sent tag '$tagName' to remote repository."
        return $true
    } catch {
        Write-Error "❌ Error pushing tag '$tagName'."
        return $false
    }
}

function DeleteRemoteTag($v) {
    $tagName = "$v"
    try {
        git push origin --delete $tagName
        Write-Host "🗑️ Remote tag '$tagName' successfully removed."
        return $true
    } catch {
        Write-Warning "⚠️ Error removing remote tag '$tagName'. She may not exists."
        return $false
    }
}

function DeleteLocalTag($v) {
    $tagName = "$v"
    try {
        git tag -d $tagName
        Write-Host "🗑️ Local Tag '$tagName' successfully removed."
        return $true
    } catch {
        Write-Warning "⚠️ Error removing local tag '$tagName'. She may not exists."
        return $false
    }
}

 
$tagName = "v$version"

if ($push -and $delete) {
    Write-Host "🔁 Combined mode: deleting and recreating tag $tagName ..."
    DeleteRemoteTag $version | Out-Null
    DeleteLocalTag $version | Out-Null

    if (CreateSignedTag $version) {
        PushTag $version | Out-Null
    }
    Exit 0;
}

if ($push) {
    if (CreateSignedTag $version) {
        PushTag $version | Out-Null
    }
    Exit 0;
}
if ($delete) {
    DeleteRemoteTag $version | Out-Null
    DeleteLocalTag $version | Out-Null
    Exit 0;
}

Write-Error '❌ Invalid option. Use -push, -delete or both.'
exit 1

