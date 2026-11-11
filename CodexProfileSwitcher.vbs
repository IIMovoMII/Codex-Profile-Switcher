Option Explicit
Dim fs, shell, root, script, dataRoot, pointer, stream, command
Set fs = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
root = fs.GetParentFolderName(WScript.ScriptFullName)
script = fs.BuildPath(root, "start-gui.ps1")

If Not fs.FileExists(script) Then
    dataRoot = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
    pointer = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "install-path.txt")
    If Not fs.FileExists(pointer) Then pointer = fs.BuildPath(dataRoot, "CodexProfileSwitcher\Launcher\install-path.txt")
    If fs.FileExists(pointer) Then
        Set stream = fs.OpenTextFile(pointer, 1, False, 0)
        root = Trim(stream.ReadAll)
        stream.Close
        If Len(root) > 0 Then script = fs.BuildPath(root, "start-gui.ps1")
    End If
End If

If Not fs.FileExists(script) Then
    MsgBox "找不到切换器程序，请重新运行安装包。", vbExclamation, "Codex 账号切换"
    WScript.Quit 1
End If

command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & script & Chr(34)
shell.Run command, 0, False
