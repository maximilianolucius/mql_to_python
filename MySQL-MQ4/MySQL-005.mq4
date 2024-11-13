//+------------------------------------------------------------------+
//|                                                    MySQL-005.mq4 |
//|                                               Maximiliano Lucius |
//|                                                             None |
//+------------------------------------------------------------------+
/*
CREATE TABLE MarketInfo.Heartbeats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp BIGINT
);
*/

#property copyright "Maximiliano Lucius"
#property link      "None"
#property version   "1.00"
#property strict
#import "kernel32.dll"
    bool GetSystemTime(ulong& lpSystemTime);
#import


#include <MQLMySQL.mqh>

string INI;
string Query;
bool VERBOSE = false;
int DB = -1; // database identifiers

string Host, User, Password, Database, Socket; // database credentials
int Port,ClientFlag;
int symbol_id = 0;


void DBConn(){
   INI = TerminalPath()+"\\MQL4\\Scripts\\MyConnection.ini";
   string terminalDataPath = TerminalInfoString(TERMINAL_DATA_PATH);
   INI = terminalDataPath + "\\MQL4\\Scripts\\MyConnection.ini";
   INI = "C:\\Users\\maxim\\AppData\\Roaming\\MetaQuotes\\Terminal\\17724769AB79540C134F349C1D0677CF\\MQL4\\Scripts\\MyConnection.ini";
   Print(INI);

   // reading database credentials from INI file
   Host = ReadIni(INI, "MYSQL", "Host");
   User = ReadIni(INI, "MYSQL", "User");
   Password = ReadIni(INI, "MYSQL", "Password");
   Database = ReadIni(INI, "MYSQL", "Database");
   Port     = StrToInteger(ReadIni(INI, "MYSQL", "Port"));
   Socket   = ReadIni(INI, "MYSQL", "Socket");
   ClientFlag = StrToInteger(ReadIni(INI, "MYSQL", "ClientFlag"));

   Print ("Host: ",Host, ", User: ", User, ", Database: ",Database);

   // open database connection
   Print ("Connecting...");
   DB = MySqlConnect(Host, User, Password, Database, Port, Socket, ClientFlag);

   if (DB == -1) {
      Print ("Connection failed! Error: "+MySqlErrorDescription);
   } else {
      Print ("Connection Succeeded!");
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit(){
//---
   EventSetTimer(100); //every 600s
   // Print (MySqlVersion());
   Print("Max");
   DBConn();
//---
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason){
//---
    EventKillTimer(); // Stop the timer events
   MySqlDisconnect(DB);
   Print ("Disconnected. Script done!");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick(){
//---
   if (DB != -1) {
        Query = "INSERT INTO MarketInfo.MarketBDSwiss (timestamp, symbol_id, ask, bid) VALUES (CAST(UNIX_TIMESTAMP(NOW(6)) * 1000 + MICROSECOND(NOW(6)) / 1000 AS UNSIGNED), "
               + IntegerToString(symbol_id) + ", " +
                        DoubleToString(Ask, 5) + ", " +
                        DoubleToString(Bid, 5) + ")";
       if (MySqlExecute(DB, Query)) {
          if (VERBOSE){
            Print ("Succeeded: ", Query);
            Print ("Rows affected: ", MySqlRowsAffected(DB));
          }
        } else {
            Print ("Error: ", MySqlErrorDescription);
            Print ("Query: ", Query);
        }
   }

}
//+------------------------------------------------------------------+
void OnTimer(){
   if (DB != -1) {
        Query = "INSERT INTO MarketInfo.MarketBDSwiss (timestamp, symbol_id, ask, bid) VALUES (CAST(UNIX_TIMESTAMP(NOW(6)) * 1000 + MICROSECOND(NOW(6)) / 1000 AS UNSIGNED), "
               + "-1 , 0.0, 0.0)";
        Query = "INSERT INTO MarketInfo.Heartbeats (timestamp) VALUES (CAST(UNIX_TIMESTAMP(NOW(6)) * 1000 + MICROSECOND(NOW(6)) / 1000 AS UNSIGNED));";

       if (MySqlExecute(DB, Query)) {
          if (VERBOSE){
            Print ("Succeeded: ", Query);
            Print ("Rows affected: ", MySqlRowsAffected(DB));
          }
        } else {
            Print ("Error: ", MySqlErrorDescription);
            Print ("Query: ", Query);
        }
   } else {
      Print ("Re-connecting...");
      DBConn();
      // DB = MySqlConnect(Host, User, Password, Database, Port, Socket, ClientFlag);

      if (DB == -1) {
         Print ("Re-connection failed! Error: "+MySqlErrorDescription);
      } else {
         Print ("Re-connection Succeeded!");
      }
   }


    for (int i = 0; i < 5; i++){
       if (MySqlExecute(DB, "SELECT 1+1")) {
           if (VERBOSE){
               Print ("Inside OnTimer.");
           }
           Print ("Heartbeat!");
           return;
       } else {
         MySqlDisconnect(DB);
         Print ("Re-Connecting...");
         Sleep(2000); // Pause for 2 seconds
         DBConn();
         // DB = MySqlConnect(Host, User, Password, Database, Port, Socket, ClientFlag);
         if (DB == -1) {
            Print ("Connection failed! Error: "+MySqlErrorDescription);
         } else {
            Print ("Connection Succeeded!");
         }
       }
    }
    Print ("Error inside OnTimer.");
    return;
}
//+------------------------------------------------------------------+
