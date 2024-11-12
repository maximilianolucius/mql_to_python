#property copyright "Meta Trader 4 Inc."
#property link      "https://www.metatrader4.com/"
#property version   "1.0"
#property strict

//--------------------------------------------------------------
// Input Parameters
//--------------------------------------------------------------

// General Parameters Section
input string t0 = "--- General Parameters ---";  // Section header for general settings
input int MILLISECOND_TIMER = 25;                // Timer interval in milliseconds

input int numLastMessages = 50;                  // Number of recent messages to retain
input string t1 = "If true, it will open charts for bar data symbols, "; // Description for chart opening
input string t2 = "which reduces the delay on a new bar.";               // Continuation of the description
input bool openChartsForBarData = true;          // Flag to open charts for bar data symbols
input bool openChartsForHistoricData = true;     // Flag to open charts for historic data symbols

// Trading Parameters Section
input string t3 = "--- Trading Parameters ---"; // Section header for trading-related settings
input int MaximumOrders = 1;                    // Maximum number of concurrent orders allowed
input double MaximumLotSize = 0.01;             // Maximum allowed lot size per order
input int SlippagePoints = 3;                   // Maximum slippage in points for order execution
input int lotSizeDigits = 2;                    // Decimal places for lot size representation

//--------------------------------------------------------------
// Global Variables
//--------------------------------------------------------------

// Command and Chart Settings
int maxCommandFiles = 50;                        // Maximum number of command files to process
int maxNumberOfCharts = 100;                     // Maximum number of charts that can be opened

// Timing Variables
long lastMessageMillis = 0;                       // Timestamp of the last message sent
long lastUpdateMillis = GetTickCount();           // Timestamp of the last market data update
long lastUpdateOrdersMillis = GetTickCount();     // Timestamp of the last orders update

// File Identifiers and Paths
string startIdentifier = "<:";                     // Marker indicating the start of a command file
string endIdentifier = ":>";                       // Marker indicating the end of a command file
string delimiter = "|";                           // Delimiter used to parse command file contents
string folderName = "mql_stuff";                        // Name of the folder to store data files
string filePathOrders = folderName + "/mql_VS_Orders.txt";               // Path to the orders data file
string filePathMessages = folderName + "/mql_VS_Messages.txt";           // Path to the messages data file
string filePathMarketData = folderName + "/mql_VS_Market_Data.txt";        // Path to the market data file
string filePathBarData = folderName + "/mql_VS_Bar_Data.txt";              // Path to the bar data file
string filePathHistoricData = folderName + "/mql_VS_Historic_Data.txt";    // Path to the historic data file
string filePathHistoricTrades = folderName + "/mql_VS_Historic_Trades.txt"; // Path to the historic trades file
string filePathCommandsPrefix = folderName + "/mql_VS_Commands_";         // Prefix for command files

// Tracking Last States
string lastOrderText = "", lastMarketDataText = "", lastMessageText = ""; // Variables to store the last written content for comparison

//--------------------------------------------------------------
// Structures
//--------------------------------------------------------------

// Structure to hold message information
struct MESSAGE
{
    long millis;       // Timestamp when the message was created
    string message;    // The message content
};

// Arrays to store messages and market data symbols
MESSAGE lastMessages[];          // Array to keep track of recent messages
string MarketDataSymbols[];      // Array of symbols subscribed for market data

// Command Tracking Variables
int commandIDindex = 0;          // Index to track the current position in the command IDs array
int commandIDs[];                // Array to store processed command IDs to prevent duplicates

//--------------------------------------------------------------
// Class Definitions
//--------------------------------------------------------------

/**
 * Class definition for a specific instrument, defined by its symbol and timeframe.
 */
class Instrument
{
public:
    //--------------------------------------------------------------
    /** 
     * Constructor initializes the instrument with default values.
     */
    Instrument()
    {
        _symbol = "";
        _name = "";
        _timeframe = PERIOD_CURRENT;
        _lastPubTime = 0;
    }

    //--------------------------------------------------------------
    /** Getters for instrument properties */
    string          symbol()    { return _symbol; }
    ENUM_TIMEFRAMES timeframe() { return _timeframe; }
    string          name()      { return _name; }
    datetime        getLastPublishTimestamp() { return _lastPubTime; }

    /** Setter for the last publish timestamp */
    void setLastPublishTimestamp(datetime tmstmp) { _lastPubTime = tmstmp; }

    //--------------------------------------------------------------
    /**
     * Sets up the instrument with the specified symbol and timeframe.
     * @param argSymbol The trading symbol (e.g., EURUSD).
     * @param argTimeframe The timeframe (e.g., M1, H1).
     */
    void setup(string argSymbol, string argTimeframe)
    {
        _symbol = argSymbol;
        _timeframe = StringToTimeFrame(argTimeframe);
        _name  = _symbol + "_" + argTimeframe;
        _lastPubTime = 0;
        SymbolSelect(_symbol, true); // Ensure the symbol is available in Market Watch

        // Optionally open a chart for the instrument to reduce data retrieval delays
        if (openChartsForBarData)
        {
            OpenChartIfNotOpen(_symbol, _timeframe);
            Sleep(200);  // Pause to allow the chart to open and data to update
        }
    }

    //--------------------------------------------------------------
    /**
     * Retrieves the last N MqlRates (OHLC data) for the instrument.
     * @param rates Array to store the retrieved rates.
     * @param count Number of rates to retrieve.
     * @return Number of rates successfully retrieved.
     */
    int GetRates(MqlRates& rates[], int count)
    {
        // Check if the symbol is properly set up before attempting to copy rates
        if (StringLen(_symbol) > 0)
            return CopyRates(_symbol, _timeframe, 1, count, rates);
        return 0;
    }

protected:
    string _name;                //!< Descriptive name of the instrument
    string _symbol;              //!< Trading symbol (e.g., EURUSD)
    ENUM_TIMEFRAMES _timeframe;  //!< Timeframe for the instrument (e.g., PERIOD_M1)
    datetime _lastPubTime;       //!< Timestamp of the last published rate. Initialized to epoch (1 Jan 1970)
};

// Array to hold all instruments subscribed for bar data publishing
Instrument BarDataInstruments[];

//--------------------------------------------------------------
// Expert Advisor Event Handlers
//--------------------------------------------------------------

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Set up a millisecond timer to trigger OnTimer events
    if (!EventSetMillisecondTimer(MILLISECOND_TIMER))
    {
        Print("EventSetMillisecondTimer() returned an error: ", ErrorDescription(GetLastError()));
        return INIT_FAILED; // Initialization failed due to timer setup error
    }

    ResetFolder();        // Initialize or reset the data folder and files
    ResetCommandIDs();    // Initialize the command IDs tracking array
    ArrayResize(lastMessages, numLastMessages); // Allocate space for recent messages

    return INIT_SUCCEEDED; // Successful initialization
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer(); // Stop the millisecond timer
    ResetFolder();    // Clean up by resetting the data folder and files
}

//+------------------------------------------------------------------+
//| Expert timer function                                            |
//+------------------------------------------------------------------+
void OnTimer()
{
    // Regularly update market data if no tick has occurred within the specified interval
    if (GetTickCount() >= lastUpdateMillis + MILLISECOND_TIMER)
        OnTick();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    /*
       Main function called on each tick or timer event to process commands,
       update orders, fetch market data, and handle bar data publishing.
    */
    lastUpdateMillis = GetTickCount(); // Update the timestamp of the last tick

    CheckCommands();       // Process any incoming commands from command files
    CheckOpenOrders();    // Update the status of open orders
    CheckMarketData();    // Retrieve and publish current market data
    CheckBarData();       // Retrieve and publish bar data for subscribed instruments
}

//--------------------------------------------------------------
//| Function to Process Command Files                               |
//--------------------------------------------------------------+

/**
 * Scans and processes command files to execute trading operations.
 * Commands are read from files with a specific prefix and format.
 */
void CheckCommands()
{
    for (int i = 0; i < maxCommandFiles; i++)
    {
        string filePath = filePathCommandsPrefix + IntegerToString(i) + ".txt"; // Construct the file path
        if (!FileIsExist(filePath))
            return; // Exit if the command file does not exist

        int handle = FileOpen(filePath, FILE_READ | FILE_TXT); // Open the command file for reading
        // Print(filePath, " | handle: ", handle);
        if (handle == -1 || handle == 0)
            return; // Exit if the file cannot be opened

        string text = "";
        // Read the entire content of the command file
        while (!FileIsEnding(handle))
            text += FileReadString(handle);
        FileClose(handle); // Close the file after reading

        // Attempt to delete the command file to prevent reprocessing
        for (int j = 0; j < 10; j++)
            if (FileDelete(filePath))
                break; // Break the loop if deletion is successful

        // Validate the command file format by checking start and end identifiers
        int length = StringLen(text);
        if (StringSubstr(text, 0, 2) != startIdentifier)
        {
            SendError("WRONG_FORMAT_START_IDENTIFIER", "Start identifier not found for command: " + text);
            return; // Exit if the start identifier is missing
        }

        if (StringSubstr(text, length - 2, 2) != endIdentifier)
        {
            SendError("WRONG_FORMAT_END_IDENTIFIER", "End identifier not found for command: " + text);
            return; // Exit if the end identifier is missing
        }

        // Extract the command content by removing the start and end identifiers
        text = StringSubstr(text, 2, length - 4);

        // Split the command content into its components using the delimiter
        ushort uSep = StringGetCharacter(delimiter, 0); // Get the delimiter character
        string data[];
        int splits = StringSplit(text, uSep, data);

        if (splits != 3)
        {
            SendError("WRONG_FORMAT_COMMAND", "Wrong format for command: " + text);
            return; // Exit if the command does not have exactly 3 parts
        }

        // Parse the command components
        int commandID = (int)data[0];    // Unique identifier for the command
        string command = data[1];        // Command type (e.g., OPEN_ORDER)
        string content = data[2];        // Command-specific content

        // Prevent duplicate command processing except for RESET_COMMAND_IDS
        if (command != "RESET_COMMAND_IDS" && CommandIDfound(commandID))
        {
            Print(StringFormat("Not executing command because ID already exists. commandID: %d, command: %s, content: %s ", commandID, command, content));
            return;
        }

        // Store the processed command ID to prevent reprocessing in the future
        commandIDs[commandIDindex] = commandID;
        commandIDindex = (commandIDindex + 1) % ArraySize(commandIDs); // Update the index circularly

        // Execute the appropriate function based on the command type
        if (command == "OPEN_ORDER")
        {
            OpenOrder(content);
        }
        else if (command == "CLOSE_ORDER")
        {
            CloseOrder(content);
        }
        else if (command == "CLOSE_ALL_ORDERS")
        {
            CloseAllOrders();
        }
        else if (command == "CLOSE_ORDERS_BY_SYMBOL")
        {
            CloseOrdersBySymbol(content);
        }
        else if (command == "CLOSE_ORDERS_BY_MAGIC")
        {
            CloseOrdersByMagic(content);
        }
        else if (command == "MODIFY_ORDER")
        {
            ModifyOrder(content);
        }
        else if (command == "SUBSCRIBE_SYMBOLS")
        {
            SubscribeSymbols(content);
        }
        else if (command == "SUBSCRIBE_SYMBOLS_BAR_DATA")
        {
            SubscribeSymbolsBarData(content);
        }
        else if (command == "GET_HISTORIC_TRADES")
        {
            GetHistoricTrades(content);
        }
        else if (command == "GET_HISTORIC_DATA")
        {
            GetHistoricData(content);
        }
        else if (command == "RESET_COMMAND_IDS")
        {
            Print("Resetting stored command IDs.");
            ResetCommandIDs(); // Clear the command IDs to allow reprocessing
        }
    }

//--------------------------------------------------------------
//| Function to Open a New Order                                    |
//--------------------------------------------------------------

/**
 * Opens a new trade order based on the provided command string.
 * @param orderStr Command string containing order details separated by delimiters.
 */
void OpenOrder(string orderStr)
{
    // Define the delimiter and split the command content into components
    string sep = ",";
    ushort uSep = StringGetCharacter(sep, 0);
    string data[];
    int splits = StringSplit(orderStr, uSep, data);

    // Validate that the command has exactly 9 components
    if (ArraySize(data) != 9)
    {
        SendError("OPEN_ORDER_WRONG_FORMAT", "Wrong format for OPEN_ORDER command: " + orderStr);
        return;
    }

    // Check if the maximum number of allowed orders has been reached
    int numOrders = NumOrders();
    if (numOrders >= MaximumOrders)
    {
        SendError("OPEN_ORDER_MAXIMUM_NUMBER", StringFormat("Number of orders (%d) larger than or equal to MaximumOrders (%d).", numOrders, MaximumOrders));
        return;
    }

    // Parse the order parameters from the command components
    string symbol = data[0];                       // Trading symbol
    int digits = (int)MarketInfo(symbol, MODE_DIGITS); // Number of decimal places for the symbol's price
    int orderType = StringToOrderType(data[1]);    // Type of order (e.g., buy, sell)
    double lots = NormalizeDouble(StringToDouble(data[2]), lotSizeDigits);   // Lot size
    double price = NormalizeDouble(StringToDouble(data[3]), digits);         // Order price
    double stopLoss = NormalizeDouble(StringToDouble(data[4]), digits);      // Stop loss level
    double takeProfit = NormalizeDouble(StringToDouble(data[5]), digits);    // Take profit level
    int magic = (int)StringToInteger(data[6]);     // Magic number for the order
    string comment = data[7];                      // Order comment
    datetime expiration = (datetime)StringToInteger(data[8]); // Expiration time for pending orders

    // If price is not specified, use the current market price based on order type
    if (price == 0 && orderType == OP_BUY)
        price = MarketInfo(symbol, MODE_ASK);
    if (price == 0 && orderType == OP_SELL)
        price = MarketInfo(symbol, MODE_BID);

    // Validate the order type
    if (orderType == -1)
    {
        SendError("OPEN_ORDER_TYPE", StringFormat("Order type could not be parsed: %d (%s)", orderType, data[1]));
        return;
    }

    // Validate that the lot size is within allowed range
    if (lots < MarketInfo(symbol, MODE_MINLOT) || lots > MarketInfo(symbol, MODE_MAXLOT))
    {
        SendError("OPEN_ORDER_LOTSIZE_OUT_OF_RANGE", StringFormat("Lot size out of range (min: %f, max: %f): %f", MarketInfo(symbol, MODE_MINLOT), MarketInfo(symbol, MODE_MAXLOT), lots));
        return;
    }

    // Ensure the lot size does not exceed the maximum allowed
    if (lots > MaximumLotSize)
    {
        SendError("OPEN_ORDER_LOTSIZE_TOO_LARGE", StringFormat("Lot size (%.2f) larger than MaximumLotSize (%.2f).", lots, MaximumLotSize));
        return;
    }

    // Ensure the order price is valid
    if (price == 0)
    {
        SendError("OPEN_ORDER_PRICE_ZERO", "Price is zero: " + orderStr);
        return;
    }

    // Attempt to send the order to the trading server
    int ticket = OrderSend(symbol, orderType, lots, price, SlippagePoints, stopLoss, takeProfit, comment, magic, expiration);
    if (ticket >= 0)
    {
        // Notify successful order placement
        SendInfo("Successfully sent order " + IntegerToString(ticket) + ": " + symbol + ", " + OrderTypeToString(orderType) + ", " + DoubleToString(lots, lotSizeDigits) + ", " + DoubleToString(price, digits));
    }
    else
    {
        // Notify failure to place the order with error details
        SendError("OPEN_ORDER", "Could not open order: " + ErrorDescription(GetLastError()));
    }
}

//--------------------------------------------------------------
//| Function to Modify an Existing Order                           |
//--------------------------------------------------------------

/**
 * Modifies an existing trade order based on the provided command string.
 * @param orderStr Command string containing order modification details separated by delimiters.
 */
void ModifyOrder(string orderStr)
{
    // Define the delimiter and split the command content into components
    string sep = ",";
    ushort uSep = StringGetCharacter(sep, 0);
    string data[];
    int splits = StringSplit(orderStr, uSep, data);

    // Validate that the command has exactly 5 components
    if (ArraySize(data) != 5)
    {
        SendError("MODIFY_ORDER_WRONG_FORMAT", "Wrong format for MODIFY_ORDER command: " + orderStr);
        return;
    }

    // Parse the order parameters from the command components
    int ticket = (int)StringToInteger(data[0]);     // Order ticket number

    // Attempt to select the order by its ticket number
    if (!OrderSelect(ticket, SELECT_BY_TICKET))
    {
        SendError("MODIFY_ORDER_SELECT_TICKET", "Could not select order with ticket: " + IntegerToString(ticket));
        return;
    }

    int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS); // Number of decimal places for the symbol's price

    double price = NormalizeDouble(StringToDouble(data[1]), digits);      // New price for the order
    double stopLoss = NormalizeDouble(StringToDouble(data[2]), digits);   // New stop loss level
    double takeProfit = NormalizeDouble(StringToDouble(data[3]), digits); // New take profit level
    datetime expiration = (datetime)StringToInteger(data[4]);             // New expiration time

    // If price is not specified, retain the original open price
    if (price == 0)
        price = OrderOpenPrice();

    // Attempt to modify the order with the new parameters
    bool res = OrderModify(ticket, price, stopLoss, takeProfit, expiration);
    if (res)
    {
        // Notify successful order modification
        SendInfo(StringFormat("Successfully modified order %d: %s, %s, %.5f, %.5f, %.5f", ticket, OrderSymbol(), OrderTypeToString(OrderType()), price, stopLoss, takeProfit));
    }
    else
    {
        // Notify failure to modify the order with error details
        SendError("MODIFY_ORDER", StringFormat("Error in modifying order %d: %s", ticket, ErrorDescription(GetLastError())));
    }
}

//--------------------------------------------------------------
//| Function to Close an Existing Order                            |
//--------------------------------------------------------------

/**
 * Closes an existing trade order based on the provided command string.
 * @param orderStr Command string containing order closure details separated by delimiters.
 */
void CloseOrder(string orderStr)
{
    // Define the delimiter and split the command content into components
    string sep = ",";
    ushort uSep = StringGetCharacter(sep, 0);
    string data[];
    int splits = StringSplit(orderStr, sep, data);

    // Validate that the command has exactly 2 components
    if (ArraySize(data) != 2)
    {
        SendError("CLOSE_ORDER_WRONG_FORMAT", "Wrong format for CLOSE_ORDER command: " + orderStr);
        return;
    }

    // Parse the order parameters from the command components
    int ticket = (int)StringToInteger(data[0]);      // Order ticket number
    double lots = NormalizeDouble(StringToDouble(data[1]), lotSizeDigits); // Lot size to close

    // Attempt to select the order by its ticket number
    if (!OrderSelect(ticket, SELECT_BY_TICKET))
    {
        SendError("CLOSE_ORDER_SELECT_TICKET", "Could not select order with ticket: " + IntegerToString(ticket));
        return;
    }

    bool res = false; // Result flag for the closure operation

    // Determine the order type and perform the appropriate closure action
    if (OrderType() == OP_BUY || OrderType() == OP_SELL)
    {
        if (lots == 0)
            lots = OrderLots(); // If lot size is not specified, close the entire order
        res = OrderClose(ticket, lots, OrderClosePrice(), SlippagePoints); // Attempt to close the order
    }
    else
    {
        res = OrderDelete(ticket); // Attempt to delete a pending order
    }

    if (res)
    {
        // Notify successful order closure
        SendInfo("Successfully closed order: " + IntegerToString(ticket) + ", " + OrderSymbol() + ", " + DoubleToString(lots, lotSizeDigits));
    }
    else
    {
        // Notify failure to close the order with error details
        SendError("CLOSE_ORDER_TICKET", "Could not close position " + IntegerToString(ticket) + ": " + ErrorDescription(GetLastError()));
    }
}

//--------------------------------------------------------------
//| Function to Close All Open Orders                               |
//--------------------------------------------------------------

/**
 * Closes all currently open and pending trade orders.
 * Iterates through all orders and attempts to close or delete them based on their type.
 */
void CloseAllOrders()
{
    int closed = 0; // Counter for successfully closed orders
    int errors = 0; // Counter for orders that failed to close

    // Iterate through all orders in reverse to safely modify the orders list
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if (!OrderSelect(i, SELECT_BY_POS))
            continue; // Skip if the order cannot be selected

        // Determine the action based on the order type
        if (OrderType() == OP_BUY || OrderType() == OP_SELL)
        {
            // Attempt to close market orders
            bool res = OrderClose(OrderTicket(), OrderLots(), OrderClosePrice(), SlippagePoints);
            if (res)
                closed++; // Increment closed counter on success
            else
                errors++; // Increment errors counter on failure
        }
        else if (OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
        {
            // Attempt to delete pending orders
            bool res = OrderDelete(OrderTicket());
            if (res)
                closed++; // Increment closed counter on success
            else
                errors++; // Increment errors counter on failure
        }
    }

    // Provide feedback based on the closure results
    if (closed == 0 && errors == 0)
        SendInfo("No orders to close.");
    if (errors > 0)
        SendError("CLOSE_ORDER_ALL", "Error during closing of " + IntegerToString(errors) + " orders.");
    else
        SendInfo("Successfully closed " + IntegerToString(closed) + " orders.");
}

//--------------------------------------------------------------
//| Function to Close Orders by Symbol                              |
//--------------------------------------------------------------

/**
 * Closes all orders associated with a specific trading symbol.
 * @param symbol The trading symbol for which orders should be closed.
 */
void CloseOrdersBySymbol(string symbol)
{
    int closed = 0; // Counter for successfully closed orders
    int errors = 0; // Counter for orders that failed to close

    // Iterate through all orders in reverse to safely modify the orders list
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        // Select the order and check if it matches the specified symbol
        if (!OrderSelect(i, SELECT_BY_POS) || OrderSymbol() != symbol)
            continue; // Skip if the order cannot be selected or symbol does not match

        // Determine the action based on the order type
        if (OrderType() == OP_BUY || OrderType() == OP_SELL)
        {
            // Attempt to close market orders
            bool res = OrderClose(OrderTicket(), OrderLots(), OrderClosePrice(), SlippagePoints);
            if (res)
                closed++; // Increment closed counter on success
            else
                errors++; // Increment errors counter on failure
        }
        else if (OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT || OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
        {
            // Attempt to delete pending orders
            bool res = OrderDelete(OrderTicket());
            if (res)
                closed++; // Increment closed counter on success
            else
                errors++; // Increment errors counter on failure
        }
    }

    // Provide feedback based on the closure results
    if (closed == 0 && errors == 0)
        SendInfo("No orders to close with symbol " + symbol + ".");
    else if (errors > 0)
        SendError("CLOSE_ORDER_SYMBOL", "Error during closing of " + IntegerToString(errors) + " orders with symbol " + symbol + ".");
    else
        SendInfo("Successfully closed " + IntegerToString(closed) + " orders with symbol " + symbol + ".");
}

//--------------------------------------------------------------
//| Function to Close Orders by Magic Number                       |
//--------------------------------------------------------------

/**
 * Closes all orders that have a specific magic number.
 * Magic numbers are used to identify orders placed by different strategies or systems.
 * @param magicStr The magic number as a string.
 */
void CloseOrdersByMagic(string magicStr)
{
    int magic = (int)StringToInteger(magicStr); // Convert magic number from string to integer

    int closed = 0; // Counter for successfully closed orders
    int errors = 0; // Counter for orders that failed to close

    // Iterate through all orders in reverse to safely modify the orders list
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        // Select the order and check if it matches the specified magic number
        if (!OrderSelect(i, SELECT_BY_POS) || OrderMagicNumber() != magic)
            continue; // Skip if the order cannot be selected or magic number does not match

        // Determine the action based on the order type
        if (OrderType() == OP_BUY || OrderType() == OP_SELL)
        {
            // Attempt to close market orders
            bool res = OrderClose(OrderTicket(), OrderLots(), OrderClosePrice(), SlippagePoints);
            if (res)
                closed++; // Increment closed counter on success
            else
                errors++; // Increment errors counter on failure
        }
        else if (OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT 
                 || OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
        {
            // Attempt to delete pending orders
            bool res = OrderDelete(OrderTicket());
            if (res)
                closed++; // Increment closed counter on success
            else
                errors++; // Increment errors counter on failure
        }
    }

    // Provide feedback based on the closure results
    if (closed == 0 && errors == 0)
        SendInfo("No orders to close with magic " + IntegerToString(magic) + ".");
    else if (errors > 0)
        SendError("CLOSE_ORDER_MAGIC", "Error during closing of " + IntegerToString(errors) + " orders with magic " + IntegerToString(magic) + ".");
    else
        SendInfo("Successfully closed " + IntegerToString(closed) + " orders with magic " + IntegerToString(magic) + ".");
}

//--------------------------------------------------------------
//| Function to Count Current Orders                                |
//--------------------------------------------------------------

/**
 * Counts the number of current open and pending trade orders.
 * @return The total number of relevant orders.
 */
int NumOrders()
{
    int n = 0; // Initialize the order count

    // Iterate through all orders to count those that are active or pending
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if (!OrderSelect(i, SELECT_BY_POS))
            continue; // Skip if the order cannot be selected

        // Check if the order type is one of the relevant types
        if (OrderType() == OP_BUY || OrderType() == OP_SELL 
            || OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT 
            || OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
        {
            n++; // Increment the count for each relevant order
        }
    }
    return n; // Return the total count
}

//--------------------------------------------------------------
//| Function to Subscribe to Market Data Symbols                   |
//--------------------------------------------------------------

/**
 * Subscribes to receive market data for specified trading symbols.
 * @param symbolsStr A comma-separated string of trading symbols.
 */
void SubscribeSymbols(string symbolsStr)
{
    string sep = ",";
    ushort uSep = StringGetCharacter(sep, 0); // Get the delimiter character
    string data[];
    int splits = StringSplit(symbolsStr, uSep, data); // Split the input string into symbols

    string successSymbols = "", errorSymbols = ""; // Strings to track successful and failed subscriptions

    // If no symbols are provided, unsubscribe from all tick data
    if (ArraySize(data) == 0)
    {
        ArrayResize(MarketDataSymbols, 0); // Clear the market data symbols array
        SendInfo("Unsubscribed from all tick data because of empty symbol list.");
        return;
    }

    // Iterate through each symbol and attempt to subscribe
    for (int i = 0; i < ArraySize(data); i++)
    {
        if (SymbolSelect(data[i], true))
        {
            ArrayResize(MarketDataSymbols, i + 1); // Resize the array to accommodate the new symbol
            MarketDataSymbols[i] = data[i];        // Add the symbol to the market data symbols array
            successSymbols += data[i] + ", ";       // Append to the success list
        }
        else
        {
            errorSymbols += data[i] + ", ";         // Append to the error list if subscription fails
        }
    }

    // Notify about any subscription errors
    if (StringLen(errorSymbols) > 0)
    {
        SendError("SUBSCRIBE_SYMBOL", "Could not subscribe to symbols: " + StringSubstr(errorSymbols, 0, StringLen(errorSymbols) - 2));
    }

    // Notify about successful subscriptions
    if (StringLen(successSymbols) > 0)
    {
        SendInfo("Successfully subscribed to: " + StringSubstr(successSymbols, 0, StringLen(successSymbols) - 2));
    }
}

//--------------------------------------------------------------
//| Function to Subscribe to Bar Data for Instruments              |
//--------------------------------------------------------------

/**
 * Subscribes to receive bar (OHLC) data for specified trading symbols and timeframes.
 * @param dataStr A comma-separated string in the format SYMBOL_1,TIMEFRAME_1,SYMBOL_2,TIMEFRAME_2,...
 */
void SubscribeSymbolsBarData(string dataStr)
{
    string sep = ",";
    ushort uSep = StringGetCharacter(sep, 0); // Get the delimiter character
    string data[];
    int splits = StringSplit(dataStr, uSep, data); // Split the input string into symbols and timeframes

    // If no data is provided, unsubscribe from all bar data
    if (ArraySize(data) == 0)
    {
        ArrayResize(BarDataInstruments, 0); // Clear the bar data instruments array
        SendInfo("Unsubscribed from all bar data because of empty symbol list.");
        return;
    }

    // Validate that the number of elements is even (symbol-timeframe pairs)
    if (ArraySize(data) < 2 || ArraySize(data) % 2 != 0)
    {
        SendError("BAR_DATA_WRONG_FORMAT", "Wrong format to subscribe to bar data: " + dataStr);
        return;
    }

    // Prepare to track any symbols that failed to subscribe
    string errorSymbols = "";

    int numInstruments = ArraySize(data) / 2; // Calculate the number of instrument pairs

    // Iterate through each symbol-timeframe pair and attempt to subscribe
    for (int s = 0; s < numInstruments; s++)
    {
        if (SymbolSelect(data[2 * s], true))
        {
            ArrayResize(BarDataInstruments, s + 1); // Resize the array to accommodate the new instrument
            BarDataInstruments[s].setup(data[2 * s], data[(2 * s) + 1]); // Set up the instrument with symbol and timeframe
        }
        else
        {
            errorSymbols += "'" + data[2 * s] + "', "; // Append to the error list if subscription fails
        }
    }

    // Format the error symbols string if there are any errors
    if (StringLen(errorSymbols) > 0)
        errorSymbols = "[" + StringSubstr(errorSymbols, 0, StringLen(errorSymbols) - 2) + "]";

    // Provide feedback based on the subscription results
    if (StringLen(errorSymbols) == 0)
    {
        SendInfo("Successfully subscribed to bar data: " + dataStr);
        CheckBarData(); // Immediately check and publish the bar data after successful subscription
    }
    else
    {
        SendError("SUBSCRIBE_BAR_DATA", "Could not subscribe to bar data for: " + errorSymbols);
    }
}

//--------------------------------------------------------------
//| Function to Retrieve Historic OHLC Data                        |
//--------------------------------------------------------------

/**
 * Retrieves historic OHLC (Open, High, Low, Close) data for a specified symbol and timeframe within a date range.
 * @param dataStr A comma-separated string containing symbol, timeframe, start date, and end date.
 */
void GetHistoricData(string dataStr)
{
    string sep = ",";
    ushort uSep = StringGetCharacter(sep, 0); // Get the delimiter character
    string data[];
    int splits = StringSplit(dataStr, uSep, data); // Split the input string into parameters

    // Validate that the command has exactly 4 components
    if (ArraySize(data) != 4)
    {
        SendError("HISTORIC_DATA_WRONG_FORMAT", "Wrong format for GET_HISTORIC_DATA command: " + dataStr);
        return;
    }

    // Parse the command parameters
    string symbol = data[0];                          // Trading symbol
    ENUM_TIMEFRAMES timeFrame = StringToTimeFrame(data[1]); // Timeframe for the data
    datetime dateStart = (datetime)StringToInteger(data[2]); // Start date for data retrieval
    datetime dateEnd = (datetime)StringToInteger(data[3]);   // End date for data retrieval

    // Validate that the symbol is provided
    if (StringLen(symbol) == 0)
    {
        SendError("HISTORIC_DATA_SYMBOL", "Could not read symbol: " + dataStr);
        return;
    }

    // Attempt to select the symbol in Market Watch
    if (!SymbolSelect(symbol, true))
    {
        SendError("HISTORIC_DATA_SELECT_SYMBOL", "Could not select symbol " + symbol + " in market watch. Error: " + ErrorDescription(GetLastError()));
    }

    // Optionally open a chart for the symbol to facilitate data retrieval
    if (openChartsForHistoricData)
    {
        // If a new chart was opened, pause to allow data to load
        if (OpenChartIfNotOpen(symbol, timeFrame))
            Sleep(200);
    }

    MqlRates rates_array[]; // Array to store the retrieved rates

    // Initialize the rates count
    int rates_count = 0;

    /*
       Attempt to retrieve historic data up to 10 times to handle potential server delays or data availability issues.
       Handles specific errors like ERR_HISTORY_WILL_UPDATED (4066) and ERR_NO_HISTORY_DATA (4073).
    */
    for (int i = 0; i < 10; i++)
    {
        rates_count = CopyRates(symbol, timeFrame, dateStart, dateEnd, rates_array); // Attempt to copy rates
        int errorCode = GetLastError(); // Retrieve the last error code

        // Exit the loop if data is successfully retrieved or if the error is not related to data availability
        if (rates_count > 0 || (errorCode != 4066 && errorCode != 4073))
            break;
        Sleep(200); // Wait before retrying
    }

    // If no data was retrieved after retries, notify the failure
    if (rates_count <= 0)
    {
        SendError("HISTORIC_DATA", "Could not get historic data for " + symbol + "_" + data[1] + ": " + ErrorDescription(GetLastError()));
        return;
    }

    bool first = true; // Flag to manage comma placement in JSON formatting
    string text = "{\"" + symbol + "_" + TimeFrameToString(timeFrame) + "\": {"; // Initialize the JSON string

    // Iterate through each retrieved rate and format it as JSON
    for (int i = 0; i < rates_count; i++)
    {
        if (first)
        {
            // Calculate the difference in days between the requested start date and the first returned rate
            double daysDifference = ((double)MathAbs(rates_array[i].time - dateStart)) / (24 * 60 * 60);
            if ((timeFrame == PERIOD_MN1 && daysDifference > 33) ||
                (timeFrame == PERIOD_W1 && daysDifference > 10) ||
                (timeFrame < PERIOD_W1 && daysDifference > 3))
            {
                SendInfo(StringFormat("The difference between requested start date and returned start date is relatively large (%.1f days). Maybe the data is not available on MetaTrader.", daysDifference));
            }
            // Print(dateStart, " | ", rates_array[i].time, " | ", daysDifference);
        }
        else
        {
            text += ", "; // Add a comma before subsequent entries
        }

        // Append the current rate's data to the JSON string
        text += StringFormat("\"%s\": {\"open\": %.5f, \"high\": %.5f, \"low\": %.5f, \"close\": %.5f, \"tick_volume\": %.5f}",
                             TimeToString(rates_array[i].time),
                             rates_array[i].open,
                             rates_array[i].high,
                             rates_array[i].low,
                             rates_array[i].close,
                             rates_array[i].tick_volume);

        first = false; // Subsequent entries will require a comma
    }

    text += "}}"; // Close the JSON object

    // Attempt to write the historic data to the designated file up to 5 times
    for (int i = 0; i < 5; i++)
    {
        if (WriteToFile(filePathHistoricData, text))
            break; // Exit the loop if writing is successful
        Sleep(100); // Wait before retrying
    }

    // Notify about the successful retrieval and writing of historic data
    SendInfo(StringFormat("Successfully read historic data for %s_%s.", symbol, data[1]));
}

//--------------------------------------------------------------
//| Function to Retrieve Historic Trade Data                       |
//--------------------------------------------------------------

/**
 * Retrieves historic trade data for orders opened within a specified lookback period.
 * @param dataStr A string representing the number of lookback days.
 */
void GetHistoricTrades(string dataStr)
{
    int lookbackDays = (int)StringToInteger(dataStr); // Convert the lookback period from string to integer

    // Validate that the lookback period is positive
    if (lookbackDays <= 0)
    {
        SendError("HISTORIC_TRADES", "Lookback days smaller or equal to zero: " + dataStr);
        return;
    }

    bool first = true; // Flag to manage comma placement in JSON formatting
    string text = "{"; // Initialize the JSON string

    // Iterate through the trade history in reverse order (most recent first)
    for (int i = OrdersHistoryTotal() - 1; i >= 0; i--)
    {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
            continue; // Skip if the order cannot be selected
        if (OrderOpenTime() < TimeCurrent() - lookbackDays * (24 * 60 * 60))
            continue; // Skip orders outside the lookback period

        if (!first)
            text += ", "; // Add a comma before subsequent entries
        else
            first = false; // The first entry does not require a comma

        // Append the trade data to the JSON string
        text += StringFormat("\"%d\": {\"magic\": %d, \"symbol\": \"%s\", \"lots\": %.2f, \"type\": \"%s\", \"open_time\": \"%s\", \"close_time\": \"%s\", \"open_price\": %.5f, \"close_price\": %.5f, \"SL\": %.5f, \"TP\": %.5f, \"pnl\": %.2f, \"commission\": %.2f, \"swap\": %.2f, \"comment\": \"%s\"}",
                             OrderTicket(),
                             OrderMagicNumber(),
                             OrderSymbol(),
                             OrderLots(),
                             OrderTypeToString(OrderType()),
                             TimeToString(OrderOpenTime(), TIME_DATE | TIME_SECONDS),
                             TimeToString(OrderCloseTime(), TIME_DATE | TIME_SECONDS),
                             OrderOpenPrice(),
                             OrderClosePrice(),
                             OrderStopLoss(),
                             OrderTakeProfit(),
                             OrderProfit(),
                             OrderCommission(),
                             OrderSwap(),
                             OrderComment());
    }
    text += "}"; // Close the JSON object

    // Attempt to write the historic trades data to the designated file up to 5 times
    for (int i = 0; i < 5; i++)
    {
        if (WriteToFile(filePathHistoricTrades, text))
            break; // Exit the loop if writing is successful
        Sleep(100); // Wait before retrying
    }

    // Notify about the successful retrieval and writing of historic trades data
    SendInfo("Successfully read historic trades.");
}

//--------------------------------------------------------------
//| Function to Update and Publish Current Market Data            |
//--------------------------------------------------------------

/**
 * Retrieves the latest market data (bid and ask prices) for all subscribed symbols
 * and publishes the data if there are any changes.
 */
void CheckMarketData()
{
    bool first = true; // Flag to manage comma placement in JSON formatting
    string text = "{"; // Initialize the JSON string

    // Iterate through all subscribed market data symbols
    for (int i = 0; i < ArraySize(MarketDataSymbols); i++)
    {
        MqlTick lastTick; // Structure to hold the latest tick data

        // Attempt to retrieve the latest tick data for the symbol
        if (SymbolInfoTick(MarketDataSymbols[i], lastTick))
        {
            if (!first)
                text += ", "; // Add a comma before subsequent entries

            // Append the tick data to the JSON string
            text += StringFormat("\"%s\": {\"bid\": %.5f, \"ask\": %.5f, \"tick_value\": %.5f}",
                                 MarketDataSymbols[i],
                                 lastTick.bid,
                                 lastTick.ask,
                                 MarketInfo(MarketDataSymbols[i], MODE_TICKVALUE));

            first = false; // Subsequent entries will require a comma
        }
        else
        {
            // Notify if tick data retrieval fails
            SendError("GET_BID_ASK", "Could not get bid/ask for " + MarketDataSymbols[i] + ". Last error: " + ErrorDescription(GetLastError()));
        }
    }

    text += "}"; // Close the JSON object

    // Only proceed to write the data if there has been a change since the last update
    if (text == lastMarketDataText)
        return;

    // Attempt to write the market data to the designated file
    if (WriteToFile(filePathMarketData, text))
    {
        lastMarketDataText = text; // Update the last market data text to the current one
    }
}

//--------------------------------------------------------------
//| Function to Update and Publish Bar Data                        |
//--------------------------------------------------------------

/**
 * Retrieves the latest bar (OHLC) data for all subscribed instruments
 * and publishes the data if there is new information.
 */
void CheckBarData()
{
    bool newData = false; // Flag to indicate if there is new bar data to publish
    string text = "{";    // Initialize the JSON string

    // Iterate through all subscribed bar data instruments
    for (int s = 0; s < ArraySize(BarDataInstruments); s++)
    {
        MqlRates curr_rate[]; // Array to hold the current rate data

        // Retrieve the latest rate for the instrument
        int count = BarDataInstruments[s].GetRates(curr_rate, 1);
        // Check if a new rate is available and if it is newer than the last published rate
        if (count > 0 && curr_rate[0].time > BarDataInstruments[s].getLastPublishTimestamp())
        {
            // Format the rate data as JSON and append it to the text string
            string rates = StringFormat("\"%s\": {\"time\": \"%s\", \"open\": %f, \"high\": %f, \"low\": %f, \"close\": %f, \"tick_volume\":%d}, ",
                                        BarDataInstruments[s].name(),
                                        TimeToString(curr_rate[0].time),
                                        curr_rate[0].open,
                                        curr_rate[0].high,
                                        curr_rate[0].low,
                                        curr_rate[0].close,
                                        curr_rate[0].tick_volume);
            text += rates;
            newData = true; // Set the flag indicating new data is available

            // Update the timestamp to the latest published rate
            BarDataInstruments[s].setLastPublishTimestamp(curr_rate[0].time);
        }
    }

    // If there is no new bar data, exit the function
    if (!newData)
        return;

    // Remove the trailing comma and space, then close the JSON object
    text = StringSubstr(text, 0, StringLen(text) - 2) + "}";
    
    // Attempt to write the bar data to the designated file up to 5 times
    for (int i = 0; i < 5; i++)
    {
        if (WriteToFile(filePathBarData, text))
            break; // Exit the loop if writing is successful
        Sleep(100); // Wait before retrying
    }
}

//--------------------------------------------------------------
//| Utility Function to Convert String to ENUM_TIMEFRAMES        |
//--------------------------------------------------------------

/**
 * Converts a timeframe string (e.g., "M1") to its corresponding ENUM_TIMEFRAMES value.
 * @param tf The timeframe string to convert.
 * @return The corresponding ENUM_TIMEFRAMES value or -1 if invalid.
 */
ENUM_TIMEFRAMES StringToTimeFrame(string tf)
{
    // Match standard timeframe strings to ENUM_TIMEFRAMES
    if (tf == "M1")
        return PERIOD_M1;
    if (tf == "M5")
        return PERIOD_M5;
    if (tf == "M15")
        return PERIOD_M15;
    if (tf == "M30")
        return PERIOD_M30;
    if (tf == "H1")
        return PERIOD_H1;
    if (tf == "H4")
        return PERIOD_H4;
    if (tf == "D1")
        return PERIOD_D1;
    if (tf == "W1")
        return PERIOD_W1;
    if (tf == "MN1")
        return PERIOD_MN1;
    return -1; // Return -1 for unknown or unsupported timeframes
}

//--------------------------------------------------------------
//| Utility Function to Convert ENUM_TIMEFRAMES to String        |
//--------------------------------------------------------------

/**
 * Converts an ENUM_TIMEFRAMES value to its corresponding string representation.
 * @param tf The ENUM_TIMEFRAMES value to convert.
 * @return The corresponding timeframe string or "UNKNOWN" if invalid.
 */
string TimeFrameToString(ENUM_TIMEFRAMES tf)
{
    // Match ENUM_TIMEFRAMES to standard timeframe strings
    switch (tf)
    {
        case PERIOD_M1:    return "M1";
        case PERIOD_M5:    return "M5";
        case PERIOD_M15:   return "M15";
        case PERIOD_M30:   return "M30";
        case PERIOD_H1:    return "H1";
        case PERIOD_H4:    return "H4";
        case PERIOD_D1:    return "D1";
        case PERIOD_W1:    return "W1";
        case PERIOD_MN1:   return "MN1";
        default:           return "UNKNOWN"; // Return "UNKNOWN" for invalid timeframes
    }
}

//--------------------------------------------------------------
//| Function to Count Open Orders with a Specific Magic Number    |
//--------------------------------------------------------------

/**
 * Counts the number of currently open orders that have a specific magic number.
 * @param _magic The magic number to search for.
 * @return The count of open orders with the specified magic number.
 */
int NumOpenOrdersWithMagic(int _magic)
{
    int n = 0; // Initialize the counter

    // Iterate through all orders to count those matching the magic number
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if (OrderSelect(i, SELECT_BY_POS) == true && OrderMagicNumber() == _magic)
        {
            n++; // Increment the counter for each matching order
        }
    }
    return n; // Return the total count
}

//--------------------------------------------------------------
//| Function to Update and Publish Open Orders Information        |
//--------------------------------------------------------------

/**
 * Retrieves information about all currently open and pending orders,
 * formats the data as JSON, and publishes it if there are changes.
 */
void CheckOpenOrders()
{
    bool first = true; // Flag to manage comma placement in JSON formatting
    // Format account and orders information as a JSON string
    string text = StringFormat("{\"account_info\": {\"name\": \"%s\", \"number\": %d, \"currency\": \"%s\", \"leverage\": %d, \"free_margin\": %f, \"balance\": %f, \"equity\": %f}, \"orders\": {",
                                AccountName(), AccountNumber(), AccountCurrency(), AccountLeverage(), AccountFreeMargin(), AccountBalance(), AccountEquity());

    // Iterate through all orders to include their details
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if (!OrderSelect(i, SELECT_BY_POS))
            continue; // Skip if the order cannot be selected

        if (!first)
            text += ", "; // Add a comma before subsequent entries

        // Append the order details to the JSON string
        text += StringFormat("\"%d\": {\"magic\": %d, \"symbol\": \"%s\", \"lots\": %.2f, \"type\": \"%s\", \"open_price\": %.5f, \"open_time\": \"%s\", \"SL\": %.5f, \"TP\": %.5f, \"pnl\": %.2f, \"commission\": %.2f, \"swap\": %.2f, \"comment\": \"%s\"}",
                             OrderTicket(),
                             OrderMagicNumber(),
                             OrderSymbol(),
                             OrderLots(),
                             OrderTypeToString(OrderType()),
                             OrderOpenPrice(),
                             TimeToString(OrderOpenTime(), TIME_DATE | TIME_SECONDS),
                             OrderStopLoss(),
                             OrderTakeProfit(),
                             OrderProfit(),
                             OrderCommission(),
                             OrderSwap(),
                             OrderComment());
        first = false; // Subsequent entries will require a comma
    }
    text += "}}"; // Close the JSON object

    /*
       To optimize performance and reduce unnecessary file writes,
       only update the orders file if there has been a change since the last update
       or if at least one second has passed since the last update.
    */
    if (text == lastOrderText && GetTickCount() < lastUpdateOrdersMillis + 1000)
        return;

    // Attempt to write the orders data to the designated file
    if (WriteToFile(filePathOrders, text))
    {
        lastUpdateOrdersMillis = GetTickCount(); // Update the last orders update timestamp
        lastOrderText = text;                     // Store the current orders data for future comparison
    }
}

//--------------------------------------------------------------
//| Function to Write Data to a File                                |
//--------------------------------------------------------------

/**
 * Writes a given text string to a specified file.
 * @param filePath The path to the file where the text should be written.
 * @param text The content to write to the file.
 * @return True if writing was successful, otherwise false.
 */
bool WriteToFile(string filePath, string text)
{
    int handle = FileOpen(filePath, FILE_WRITE | FILE_TXT); // Open the file for writing as a text file
    if (handle == -1)
        return false; // Return false if the file could not be opened

    // Write the text to the file. Note: Even an empty string writes two bytes (newline).
    uint numBytesWritten = FileWrite(handle, text);
    FileClose(handle); // Close the file after writing

    return numBytesWritten > 0; // Return true if at least one byte was written
}

//--------------------------------------------------------------
//| Function to Send Error Messages                                 |
//--------------------------------------------------------------

/**
 * Sends an error message by logging it and publishing it as JSON.
 * @param errorType A short identifier for the type of error.
 * @param errorDescription A detailed description of the error.
 */
void SendError(string errorType, string errorDescription)
{
    Print("ERROR: " + errorType + " | " + errorDescription); // Log the error to the terminal

    // Format the error message as a JSON string
    string message = StringFormat("{\"type\": \"ERROR\", \"time\": \"%s %s\", \"error_type\": \"%s\", \"description\": \"%s\"}",
                                  TimeToString(TimeGMT(), TIME_DATE), TimeToString(TimeGMT(), TIME_SECONDS), errorType, errorDescription);

    SendMessage(message); // Publish the error message
}

//--------------------------------------------------------------
//| Function to Send Informational Messages                       |
//--------------------------------------------------------------

/**
 * Sends an informational message by logging it and publishing it as JSON.
 * @param message The informational message to send.
 */
void SendInfo(string message)
{
    Print("INFO: " + message); // Log the information to the terminal

    // Format the informational message as a JSON string
    message = StringFormat("{\"type\": \"INFO\", \"time\": \"%s %s\", \"message\": \"%s\"}",
                           TimeToString(TimeGMT(), TIME_DATE), TimeToString(TimeGMT(), TIME_SECONDS), message);

    SendMessage(message); // Publish the informational message
}

//--------------------------------------------------------------
//| Function to Handle Message Publishing                           |
//--------------------------------------------------------------

/**
 * Publishes a message by adding it to the recent messages array and writing it to the messages file.
 * Ensures that messages are unique and manages the storage of recent messages.
 * @param message The message content to publish.
 */
void SendMessage(string message)
{
    // Shift existing messages in the array to make room for the new message
    for (int i = ArraySize(lastMessages) - 1; i >= 1; i--)
    {
        lastMessages[i] = lastMessages[i - 1];
    }

    // Assign the current tick count as the message timestamp
    lastMessages[0].millis = GetTickCount();

    // Ensure that each message has a unique timestamp
    if (lastMessages[0].millis <= lastMessageMillis)
        lastMessages[0].millis = lastMessageMillis + 1;
    lastMessageMillis = lastMessages[0].millis;

    // Store the message content
    lastMessages[0].message = message;

    bool first = true; // Flag to manage comma placement in JSON formatting
    string text = "{"; // Initialize the JSON string

    // Iterate through the recent messages in reverse order to include them in the JSON
    for (int i = ArraySize(lastMessages) - 1; i >= 0; i--)
    {
        if (StringLen(lastMessages[i].message) == 0)
            continue; // Skip empty messages

        if (!first)
            text += ", "; // Add a comma before subsequent entries

        // Append the message to the JSON string using its timestamp as the key
        text += "\"" + IntegerToString(lastMessages[i].millis) + "\": " + lastMessages[i].message;
        first = false; // Subsequent entries will require a comma
    }
    text += "}"; // Close the JSON object

    // Only proceed to write the messages file if there has been a change since the last update
    if (text == lastMessageText)
        return;

    // Attempt to write the messages data to the designated file
    if (WriteToFile(filePathMessages, text))
        lastMessageText = text; // Update the last message text to the current one
}

//--------------------------------------------------------------
//| Function to Open a Chart if Not Already Open                   |
//--------------------------------------------------------------

/**
 * Opens a chart for a specific symbol and timeframe if it is not already open.
 * @param symbol The trading symbol for which to open the chart.
 * @param timeFrame The timeframe for the chart.
 * @return True if a new chart was opened, otherwise false.
 */
bool OpenChartIfNotOpen(string symbol, ENUM_TIMEFRAMES timeFrame)
{
    // Retrieve the ID of the first chart
    long chartID = ChartFirst();

    // Iterate through existing charts to check if the desired chart is already open
    for (int i = 0; i < maxNumberOfCharts; i++)
    {
        if (StringLen(ChartSymbol(chartID)) > 0) // Check if the chart has an associated symbol
        {
            if (ChartSymbol(chartID) == symbol && ChartPeriod(chartID) == timeFrame)
            {
                // Notify that the chart is already open
                Print(StringFormat("Chart already open (%s, %s).", symbol, TimeFrameToString(timeFrame)));
                return false; // No need to open a new chart
            }
        }
        chartID = ChartNext(chartID); // Move to the next chart
        if (chartID == -1)
            break; // Exit if there are no more charts
    }

    // Attempt to open a new chart for the specified symbol and timeframe
    long id = ChartOpen(symbol, timeFrame);
    if (id > 0)
    {
        // Notify that the chart has been successfully opened
        Print(StringFormat("Chart opened (%s, %s).", symbol, TimeFrameToString(timeFrame)));
        return true; // A new chart was opened
    }
    else
    {
        // Notify that the chart could not be opened
        SendError("OPEN_CHART", StringFormat("Could not open chart (%s, %s).", symbol, TimeFrameToString(timeFrame)));
        return false; // Failed to open the chart
    }
}

//--------------------------------------------------------------
//| Function to Reset Command IDs                                   |
//--------------------------------------------------------------

/**
 * Resets the command IDs tracking array by initializing all elements to -1.
 * This prevents processing of duplicate commands by clearing the history.
 */
void ResetCommandIDs()
{
    ArrayResize(commandIDs, 1000); // Allocate space for the last 1000 command IDs
    ArrayFill(commandIDs, 0, ArraySize(commandIDs), -1); // Initialize all elements to -1
    commandIDindex = 0; // Reset the index to start from the beginning
}

//--------------------------------------------------------------
//| Function to Check if a Command ID has Already Been Processed  |
//--------------------------------------------------------------

/**
 * Checks if a given command ID has already been processed to avoid duplicate executions.
 * @param id The command ID to check.
 * @return True if the command ID is found, otherwise false.
 */
bool CommandIDfound(int id)
{
    // Iterate through the command IDs array to find a match
    for (int i = 0; i < ArraySize(commandIDs); i++)
        if (id == commandIDs[i])
            return true; // Command ID has been processed before
    return false; // Command ID is new and has not been processed
}

//--------------------------------------------------------------
//| Utility Function to Convert Order Type to String               |
//--------------------------------------------------------------

/**
 * Converts an order type constant to its corresponding string representation.
 * @param orderType The order type constant (e.g., OP_BUY).
 * @return The corresponding order type string or "unknown" if invalid.
 */
string OrderTypeToString(int orderType)
{
    if (orderType == OP_BUY)
        return "buy";
    if (orderType == OP_SELL)
        return "sell";
    if (orderType == OP_BUYLIMIT)
        return "buylimit";
    if (orderType == OP_SELLLIMIT)
        return "selllimit";
    if (orderType == OP_BUYSTOP)
        return "buystop";
    if (orderType == OP_SELLSTOP)
        return "sellstop";
    return "unknown"; // Return "unknown" for unrecognized order types
}

//--------------------------------------------------------------
//| Utility Function to Convert String to Order Type               |
//--------------------------------------------------------------

/**
 * Converts an order type string to its corresponding order type constant.
 * @param orderTypeStr The order type string (e.g., "buy").
 * @return The corresponding order type constant or -1 if invalid.
 */
int StringToOrderType(string orderTypeStr)
{
    if (orderTypeStr == "buy")
        return OP_BUY;
    if (orderTypeStr == "sell")
        return OP_SELL;
    if (orderTypeStr == "buylimit")
        return OP_BUYLIMIT;
    if (orderTypeStr == "selllimit")
        return OP_SELLLIMIT;
    if (orderTypeStr == "buystop")
        return OP_BUYSTOP;
    if (orderTypeStr == "sellstop")
        return OP_SELLSTOP;
    return -1; // Return -1 for unrecognized order types
}

//--------------------------------------------------------------
//| Function to Reset the Data Folder and Clean Up Files           |
//--------------------------------------------------------------

/**
 * Resets the data folder by recreating it and deleting all existing data files.
 * Ensures a clean state by removing old data and preparing for new data storage.
 */
void ResetFolder()
{
    // Attempt to delete the existing folder (commented out as it may not always work)
    // FolderDelete(folderName);  // Does not always work.

    FolderCreate(folderName); // Create the data folder

    // Delete existing data files to ensure a clean state
    FileDelete(filePathMarketData);
    FileDelete(filePathBarData);
    FileDelete(filePathHistoricData);
    FileDelete(filePathOrders);
    FileDelete(filePathMessages);

    // Delete all existing command files
    for (int i = 0; i < maxCommandFiles; i++)
    {
        FileDelete(filePathCommandsPrefix + IntegerToString(i) + ".txt");
    }
}

//--------------------------------------------------------------
//| Function to Retrieve Error Descriptions                        |
//--------------------------------------------------------------

/**
 * Provides a human-readable description for a given error code.
 * Covers both trade server errors and MQL4-specific errors.
 * @param errorCode The error code to describe.
 * @return A string describing the error.
 */
string ErrorDescription(int errorCode)
{
    string errorString;

    switch (errorCode)
    {
        //---- Codes returned from trade server
        case 0:
        case 1:
            errorString = "no error";
            break;
        case 2:
            errorString = "common error";
            break;
        case 3:
            errorString = "invalid trade parameters";
            break;
        case 4:
            errorString = "trade server is busy";
            break;
        case 5:
            errorString = "old version of the client terminal";
            break;
        case 6:
            errorString = "no connection with trade server";
            break;
        case 7:
            errorString = "not enough rights";
            break;
        case 8:
            errorString = "too frequent requests";
            break;
        case 9:
            errorString = "malfunctional trade operation (never returned error)";
            break;
        case 64:
            errorString = "account disabled";
            break;
        case 65:
            errorString = "invalid account";
            break;
        case 128:
            errorString = "trade timeout";
            break;
        case 129:
            errorString = "invalid price";
            break;
        case 130:
            errorString = "invalid stops";
            break;
        case 131:
            errorString = "invalid trade volume";
            break;
        case 132:
            errorString = "market is closed";
            break;
        case 133:
            errorString = "trade is disabled";
            break;
        case 134:
            errorString = "not enough money";
            break;
        case 135:
            errorString = "price changed";
            break;
        case 136:
            errorString = "off quotes";
            break;
        case 137:
            errorString = "broker is busy (never returned error)";
            break;
        case 138:
            errorString = "requote";
            break;
        case 139:
            errorString = "order is locked";
            break;
        case 140:
            errorString = "long positions only allowed";
            break;
        case 141:
            errorString = "too many requests";
            break;
        case 145:
            errorString = "modification denied because order too close to market";
            break;
        case 146:
            errorString = "trade context is busy";
            break;
        case 147:
            errorString = "expirations are denied by broker";
            break;
        case 148:
            errorString = "amount of open and pending orders has reached the limit";
            break;
        case 149:
            errorString = "hedging is prohibited";
            break;
        case 150:
            errorString = "prohibited by FIFO rules";
            break;

        //---- MQL4-specific errors
        case 4000:
            errorString = "no error (never generated code)";
            break;
        case 4001:
            errorString = "wrong function pointer";
            break;
        case 4002:
            errorString = "array index is out of range";
            break;
        case 4003:
            errorString = "no memory for function call stack";
            break;
        case 4004:
            errorString = "recursive stack overflow";
            break;
        case 4005:
            errorString = "not enough stack for parameter";
            break;
        case 4006:
            errorString = "no memory for parameter string";
            break;
        case 4007:
            errorString = "no memory for temp string";
            break;
        case 4008:
            errorString = "not initialized string";
            break;
        case 4009:
            errorString = "not initialized string in array";
            break;
        case 4010:
            errorString = "no memory for array's string";
            break;
        case 4011:
            errorString = "too long string";
            break;
        case 4012:
            errorString = "remainder from zero divide";
            break;
        case 4013:
            errorString = "zero divide";
            break;
        case 4014:
            errorString = "unknown command";
            break;
        case 4015:
            errorString = "wrong jump (never generated error)";
            break;
        case 4016:
            errorString = "not initialized array";
            break;
        case 4017:
            errorString = "dll calls are not allowed";
            break;
        case 4018:
            errorString = "cannot load library";
            break;
        case 4019:
            errorString = "cannot call function";
            break;
        case 4020:
            errorString = "expert function calls are not allowed";
            break;
        case 4021:
            errorString = "not enough memory for temp string returned from function";
            break;
        case 4022:
            errorString = "system is busy (never generated error)";
            break;
        case 4050:
            errorString = "invalid function parameters count";
            break;
        case 4051:
            errorString = "invalid function parameter value";
            break;
        case 4052:
            errorString = "string function internal error";
            break;
        case 4053:
            errorString = "some array error";
            break;
        case 4054:
            errorString = "incorrect series array using";
            break;
        case 4055:
            errorString = "custom indicator error";
            break;
        case 4056:
            errorString = "arrays are incompatible";
            break;
        case 4057:
            errorString = "global variables processing error";
            break;
        case 4058:
            errorString = "global variable not found";
            break;
        case 4059:
            errorString = "function is not allowed in testing mode";
            break;
        case 4060:
            errorString = "function is not confirmed";
            break;
        case 4061:
            errorString = "send mail error";
            break;
        case 4062:
            errorString = "string parameter expected";
            break;
        case 4063:
            errorString = "integer parameter expected";
            break;
        case 4064:
            errorString = "double parameter expected";
            break;
        case 4065:
            errorString = "array as parameter expected";
            break;
        case 4066:
            errorString = "requested history data in update state";
            break;
        case 4099:
            errorString = "end of file";
            break;
        case 4100:
            errorString = "some file error";
            break;
        case 4101:
            errorString = "wrong file name";
            break;
        case 4102:
            errorString = "too many opened files";
            break;
        case 4103:
            errorString = "cannot open file";
            break;
        case 4104:
            errorString = "incompatible access to a file";
            break;
        case 4105:
            errorString = "no order selected";
            break;
        case 4106:
            errorString = "unknown symbol";
            break;
        case 4107:
            errorString = "invalid price parameter for trade function";
            break;
        case 4108:
            errorString = "invalid ticket";
            break;
        case 4109:
            errorString = "trade is not allowed in the expert properties";
            break;
        case 4110:
            errorString = "longs are not allowed in the expert properties";
            break;
        case 4111:
            errorString = "shorts are not allowed in the expert properties";
            break;
        case 4200:
            errorString = "object already exists";
            break;
        case 4201:
            errorString = "unknown object property";
            break;
        case 4202:
            errorString = "object does not exist";
            break;
        case 4203:
            errorString = "unknown object type";
            break;
        case 4204:
            errorString = "no object name";
            break;
        case 4205:
            errorString = "object coordinates error";
            break;
        case 4206:
            errorString = "no specified subwindow";
            break;
        default:
            errorString = "ErrorCode: " + IntegerToString(errorCode); // Default case for unknown errors
    }
    return (errorString); // Return the error description
}

//--------------------------------------------------------------
//| Function to Print an Array of Strings                             |
//--------------------------------------------------------------

/**
 * Utility function to print the contents of a string array to the terminal.
 * @param arr The string array to print.
 */
void printArray(string &arr[])
{
    if (ArraySize(arr) == 0)
        Print("{}"); // Print empty braces if the array is empty

    string printStr = "{"; // Initialize the string with an opening brace
    int i;
    for (i = 0; i < ArraySize(arr); i++)
    {
        if (i == ArraySize(arr) - 1)
            printStr += arr[i]; // Append the last element without a trailing comma
        else
            printStr += arr[i] + ", "; // Append elements with a trailing comma and space
    }
    Print(printStr + "}"); // Close the string with a closing brace and print it
}

//--------------------------------------------------------------
//| End of Code                                                      |
//--------------------------------------------------------------+
