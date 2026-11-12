Option Explicit
Dim fs, shell, launcherDirectory, appRoot, appPath, args, item, command
Set fs = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
launcherDirectory = fs.GetParentFolderName(WScript.ScriptFullName)
appRoot = ResolveRoot(launcherDirectory)
If Len(appRoot) = 0 Then appRoot = ResolvePointer(fs.BuildPath(launcherDirectory, "install-path.txt"))
If Len(appRoot) = 0 Then appRoot = ResolvePointer(fs.BuildPath(shell.ExpandEnvironmentStrings("%LOCALAPPDATA%"), "CodexProfileSwitcher\Launcher\install-path.txt"))
If Len(appRoot) = 0 Then appRoot = ResolveRoot(fs.BuildPath(shell.ExpandEnvironmentStrings("%LOCALAPPDATA%"), "Programs\CodexProfileSwitcher"))
If Len(appRoot) = 0 Then
    Dim missingMessage
    missingMessage = UnicodeText("627E 4E0D 5230 5207 6362 5668 7A0B 5E8F FF0C 8BF7 91CD 65B0 8FD0 884C 5B89 88C5 5305 3002")
    If LCase(fs.GetFileName(WScript.FullName)) = "cscript.exe" Then
        WScript.Echo missingMessage
    Else
        MsgBox missingMessage, vbExclamation, "Codex " & UnicodeText("8D26 53F7 5207 6362")
    End If
    WScript.Quit 1
End If
appPath = fs.BuildPath(appRoot, "CodexProfileSwitcher.exe")
args = ""
For Each item In WScript.Arguments
    args = args & " " & QuoteArgument(CStr(item))
Next
command = QuoteArgument(appPath) & args
shell.CurrentDirectory = appRoot
Dim exitCode
exitCode = shell.Run(command, 1, True)
WScript.Quit exitCode

Function ResolveRoot(candidate)
    On Error Resume Next
    Dim publishPointer, publishRoot, candidatePath
    ResolveRoot = ""
    If Len(candidate) = 0 Then Exit Function
    If fs.FileExists(fs.BuildPath(candidate, "CodexProfileSwitcher.exe")) Then
        ResolveRoot = candidate
        Exit Function
    End If
    publishPointer = fs.BuildPath(candidate, "artifacts\publish\current-path.txt")
    publishRoot = ReadPointer(publishPointer, "utf-8")
    If Len(publishRoot) > 0 Then
        If fs.FileExists(fs.BuildPath(publishRoot, "CodexProfileSwitcher.exe")) Then
            ResolveRoot = publishRoot
            Exit Function
        End If
    End If
    For Each candidatePath In Array("artifacts\publish\desktop", "src\Switcher.Desktop\bin\Release\net10.0-windows\win-x64\publish")
        publishRoot = fs.BuildPath(candidate, candidatePath)
        If fs.FileExists(fs.BuildPath(publishRoot, "CodexProfileSwitcher.exe")) Then
            ResolveRoot = publishRoot
            Exit Function
        End If
    Next
End Function

Function ResolvePointer(path)
    Dim encoding, value
    ResolvePointer = ""
    For Each encoding In Array("utf-8", "unicode", "ansi")
        value = ReadPointer(path, encoding)
        If Len(value) > 0 Then ResolvePointer = ResolveRoot(value)
        If Len(ResolvePointer) > 0 Then Exit Function
    Next
End Function

Function ReadPointer(path, encoding)
    On Error Resume Next
    Dim stream, value
    ReadPointer = ""
    If Not fs.FileExists(path) Then Exit Function
    Err.Clear
    If encoding = "ansi" Then
        Set stream = fs.OpenTextFile(path, 1, False, 0)
        value = stream.ReadAll
    Else
        Set stream = CreateObject("ADODB.Stream")
        stream.Type = 2
        stream.Charset = encoding
        stream.Open
        stream.LoadFromFile path
        value = stream.ReadText
    End If
    If Err.Number = 0 Then ReadPointer = Trim(Replace(value, ChrW(&HFEFF), ""))
    stream.Close
End Function

Function UnicodeText(hexCodes)
    Dim code, result
    result = ""
    For Each code In Split(hexCodes, " ")
        result = result & ChrW(CLng("&H" & code))
    Next
    UnicodeText = result
End Function

Function QuoteArgument(value)
    Dim i, ch, slashes, result
    result = Chr(34)
    slashes = 0
    For i = 1 To Len(value)
        ch = Mid(value, i, 1)
        If ch = Chr(92) Then
            slashes = slashes + 1
        ElseIf ch = Chr(34) Then
            result = result & String(slashes * 2 + 1, Chr(92)) & Chr(34)
            slashes = 0
        Else
            result = result & String(slashes, Chr(92)) & ch
            slashes = 0
        End If
    Next
    result = result & String(slashes * 2, Chr(92)) & Chr(34)
    QuoteArgument = result
End Function
