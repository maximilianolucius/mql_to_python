//+------------------------------------------------------------------+
//|                                             ExportDataToCSV2.mq4 |
//|                                               Maximiliano Lucius |
//|                                                             None |
//+------------------------------------------------------------------+
#property copyright "Maximiliano Lucius"
#property link      "None"
#property version   "1.00"
#property strict
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+

int fileHandle;


int OnInit(){
//---
    string fileName = _Symbol + "-ticks.csv";
    fileHandle = FileOpen(fileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
    if(fileHandle != INVALID_HANDLE){
        // File opened successfully
        // You can perform any additional initialization tasks here if needed
        FileSeek(fileHandle, 0, SEEK_END); // Move to the end of the file
        FileWrite(fileHandle, "datetime,Price");
        Print("We are ready for ... ", _Symbol);
    } else {
        // Failed to open file
        Print("Failed to open file for writing: ", fileName);
    }

    return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason){
//---
    FileClose(fileHandle);
    Print("Tha's all!");
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick(){
//---
    // Get current time in UTC 0 TimeMilliseconds
    datetime currentTime = TimeCurrent();

    // Convert current time to string
    //string timeString = TimeToString(currentTime, TIME_DATE|TIME_MINUTES);
    MqlDateTime str1;
    TimeToStruct(currentTime, str1);

    // Formatting each component with desired precision
    string timeString = StringFormat("%04d-%02d-%02d %02d:%02d:%06.3f", str1.year, str1.mon, str1.day, str1.hour, str1.min, str1.sec);

    FileWrite(fileHandle, timeString + "," + DoubleToString(Ask, _Digits));
}
//+------------------------------------------------------------------+
