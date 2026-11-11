Option Explicit
Dim fs, shell, root, script, dataRoot, pointer, stream, command, missingMessage
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
    missingMessage = ChrW(&H627E) & ChrW(&H4E0D) & ChrW(&H5230) & ChrW(&H5207) & ChrW(&H6362) & ChrW(&H5668) & ChrW(&H7A0B) & ChrW(&H5E8F) & ChrW(&HFF0C) & ChrW(&H8BF7) & ChrW(&H91CD) & ChrW(&H65B0) & ChrW(&H8FD0) & ChrW(&H884C) & ChrW(&H5B89) & ChrW(&H88C5) & ChrW(&H5305) & ChrW(&H3002)
    MsgBox missingMessage, vbExclamation, "Codex " & ChrW(&H8D26) & ChrW(&H53F7) & ChrW(&H5207) & ChrW(&H6362)
    WScript.Quit 1
End If

command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & script & Chr(34)
shell.Run command, 0, False
