// Minimal command-line bridge for the SQLite library supplied with Windows.
// Implements only the flags and .backup operation used by this application.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowsSqlite {
    const string Lib = "winsqlite3.dll";
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] path, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_libversion();
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_busy_timeout(IntPtr db,int ms);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db,IntPtr sql,int length,out IntPtr stmt,out IntPtr tail);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_name(IntPtr stmt,int col);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_column_type(IntPtr stmt,int col);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt,int col);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern long sqlite3_column_int64(IntPtr stmt,int col);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern double sqlite3_column_double(IntPtr stmt,int col);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_backup_init(IntPtr dest,byte[] destName,IntPtr source,byte[] sourceName);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_backup_step(IntPtr backup,int pages);
    [DllImport(Lib, CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_backup_finish(IntPtr backup);
    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s+"\0"); }
    static string Text(IntPtr ptr) {
        if(ptr==IntPtr.Zero) return "";
        int size=0; while(Marshal.ReadByte(ptr,size)!=0) size++;
        byte[] bytes=new byte[size]; Marshal.Copy(ptr,bytes,0,size); return Encoding.UTF8.GetString(bytes);
    }
    static void Check(int code,IntPtr db) { if(code!=0) throw new Exception(Text(sqlite3_errmsg(db))); }
    static void Backup(IntPtr source,string file) {
        file=file.Trim();
        if(file.Length>=2 && file[0]=='\'' && file[file.Length-1]=='\'') file=file.Substring(1,file.Length-2).Replace("''","'");
        else if(file.Length>=2 && file[0]=='"' && file[file.Length-1]=='"') file=file.Substring(1,file.Length-2);
        IntPtr dest; Check(sqlite3_open_v2(Z(file),out dest,6|64,IntPtr.Zero),dest);
        try {
            IntPtr backup=sqlite3_backup_init(dest,Z("main"),source,Z("main"));
            if(backup==IntPtr.Zero) throw new Exception(Text(sqlite3_errmsg(dest)));
            int result;
            try { result=sqlite3_backup_step(backup,-1); }
            finally { sqlite3_backup_finish(backup); }
            if(result!=101) throw new Exception("SQLite backup failed: "+result);
        } finally { sqlite3_close(dest); }
    }
    static void Run(IntPtr db,string sql,bool json,string separator) {
        sql=sql.Trim(); if(sql.Length==0) return;
        if(sql.StartsWith(".timeout ",StringComparison.Ordinal)) { sqlite3_busy_timeout(db,int.Parse(sql.Substring(9).Trim(),CultureInfo.InvariantCulture)); return; }
        if(sql.StartsWith(".backup ",StringComparison.Ordinal)) { Backup(db,sql.Substring(8));return; }
        byte[] bytes=Z(sql); IntPtr buffer=Marshal.AllocHGlobal(bytes.Length);Marshal.Copy(bytes,0,buffer,bytes.Length);
        var rows=new List<Dictionary<string,object>>();
        try {
            IntPtr current=buffer, end=new IntPtr(buffer.ToInt64()+bytes.Length-1);
            while(current.ToInt64()<end.ToInt64()) {
                IntPtr stmt,tail;Check(sqlite3_prepare_v2(db,current,-1,out stmt,out tail),db);
                if(tail.ToInt64()<=current.ToInt64()) break;
                current=tail;if(stmt==IntPtr.Zero) continue;
                try {
                    int code;
                    while((code=sqlite3_step(stmt))==100) {
                        int count=sqlite3_column_count(stmt);var values=new string[count];var row=new Dictionary<string,object>();
                        for(int i=0;i<count;i++) {
                            int type=sqlite3_column_type(stmt,i);object value=null;
                            if(type==1) value=sqlite3_column_int64(stmt,i);
                            else if(type==2) value=sqlite3_column_double(stmt,i);
                            else if(type!=5) value=Text(sqlite3_column_text(stmt,i));
                            values[i]=value==null?"":Convert.ToString(value,CultureInfo.InvariantCulture);
                            if(json) row[Text(sqlite3_column_name(stmt,i))]=value;
                        }
                        if(json) rows.Add(row);else Console.WriteLine(string.Join(separator,values));
                    }
                    if(code!=101) Check(code,db);
                } finally { sqlite3_finalize(stmt); }
            }
        } finally {Marshal.FreeHGlobal(buffer);}
        if(json) Console.WriteLine(Json(rows));
    }
    static string Json(object value) {
        if(value==null)return "null";
        if(value is string){var b=new StringBuilder("\"");foreach(char c in (string)value){if(c=='"'||c=='\\')b.Append('\\').Append(c);else if(c<32)b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}
        var map=value as Dictionary<string,object>;if(map!=null){var parts=new List<string>();foreach(var pair in map)parts.Add(Json(pair.Key)+":"+Json(pair.Value));return "{"+string.Join(",",parts)+"}";}
        var rows=value as List<Dictionary<string,object>>;if(rows!=null){var parts=new List<string>();foreach(var row in rows)parts.Add(Json(row));return "["+string.Join(",",parts)+"]";}
        return Convert.ToString(value,CultureInfo.InvariantCulture);
    }
    public static int Execute(string[] args,string input) {
        IntPtr db=IntPtr.Zero;
        try {
            bool readOnly=false,json=false;string path=null,sql=null,separator="|";var initial=new List<string>();
            for(int i=0;i<args.Length;i++) {
                string arg=args[i];
                if(arg=="-version" || arg=="--version"){Console.WriteLine(Text(sqlite3_libversion())+" (Windows SQLite)");return 0;}
                if(arg=="-readonly"){readOnly=true;continue;}if(arg=="-json"){json=true;continue;}
                if(arg=="-batch"||arg=="-bail"||arg=="-noheader")continue;
                if(arg=="-cmd"){initial.Add(args[++i]);continue;}
                if(arg=="-separator"){separator=args[++i];continue;}
                if(path==null){if(arg.StartsWith("-"))throw new Exception("Unsupported SQLite option: "+arg);path=arg;}
                else if(sql==null)sql=arg;else throw new Exception("Unexpected SQLite argument.");
            }
            if(path==null)throw new Exception("A database path is required.");
            Check(sqlite3_open_v2(Z(path),out db,(readOnly?1:6)|64,IntPtr.Zero),db);sqlite3_busy_timeout(db,5000);
            foreach(string command in initial)Run(db,command,false,separator);
            Run(db,sql??input,json,separator);return 0;
        }catch(Exception ex){Console.Error.WriteLine("SQLite: "+ex.Message);return 1;}
        finally{if(db!=IntPtr.Zero)sqlite3_close(db);}
    }
}
