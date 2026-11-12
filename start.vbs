Option Explicit
Dim fs, shell, entry, args, item, exitCode
Set fs = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
entry = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "CodexProfileSwitcher.vbs")
args = ""
For Each item In WScript.Arguments
    args = args & " " & QuoteArgument(CStr(item))
Next
exitCode = shell.Run(QuoteArgument(entry) & args, 1, True)
WScript.Quit exitCode

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
