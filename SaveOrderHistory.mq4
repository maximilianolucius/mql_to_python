// Expert initialization function
int startTime = 0;

int OnInit() {
    startTime = TimeCurrent(); // Record the start time
    EventSetTimer(200);      // Set the timer to trigger every 24 hours (86400 seconds)
    SaveOrderHistoryToCSV();
    return INIT_SUCCEEDED;
}

// Expert deinitialization function
void OnDeinit(const int reason) {
    EventKillTimer();          // Kill the timer on deinit
}

// Timer event handler - runs every 24 hours
void OnTimer() {
    if (TimeCurrent() - startTime >= 7200) {
        SaveOrderHistoryToCSV();
        startTime = TimeCurrent();  // Reset start time
    }
}

// Function to save all order history to CSV
void SaveOrderHistoryToCSV() {
    string accountNumber = AccountNumber();
    string fileName = StringFormat("history-orders-%d.csv", accountNumber);
    // string filePath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\" + fileName;
    // string filePath = "C:\\Temp\\" + fileName;
    string filePath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\" + fileName;
    Print(filePath);

    int fileHandle = FileOpen("history-orders-" +  accountNumber + ".csv", FILE_CSV | FILE_WRITE, ','); // ---

    if (fileHandle < 0) {
        Print("Error opening file: ", GetLastError());
        return;
    }

    // Write the header row
    FileWrite(fileHandle, "OrderTicket", "OrderType", "Symbol", "Volume", "OpenPrice", "OpenTime", "ClosePrice", "CloseTime", "Profit");

    // Loop through all orders in history
    int totalOrders = OrdersHistoryTotal();
    for (int i = 0; i < totalOrders; i++) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) {
            FileWrite(fileHandle,
                      OrderTicket(),
                      OrderType(),
                      OrderSymbol(),
                      OrderLots(),
                      OrderOpenPrice(),
                      TimeToString(OrderOpenTime(), TIME_DATE | TIME_MINUTES),
                      OrderClosePrice(),
                      TimeToString(OrderCloseTime(), TIME_DATE | TIME_MINUTES),
                      OrderProfit());
        }
    }

    FileClose(fileHandle);
    Print("Order history saved to: ", filePath);
}

// Expert tick function - not used, but required
void OnTick() {
    // No logic needed for OnTick in this EA
}
