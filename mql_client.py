import os
import json
from time import sleep
from threading import Thread, Lock
from os.path import join, exists
from traceback import print_exc
from datetime import datetime, timezone, timedelta


class mql_client:
    """
    A client to interact with MetaTrader via file-based communication.

    This class handles subscribing to market data, managing orders, and retrieving
    historic data by communicating with MetaTrader through designated files. It
    supports asynchronous operations using multiple threads and provides event
    handling through an optional event_handler.
    """

    def __init__(self, event_handler=None, metatrader_dir_path='',
                 sleep_delay=0.005,
                 max_retry_command_seconds=10,
                 load_orders_from_file=True,
                 verbose=True
                 ):
        """
        Initializes the mql_client instance with configuration parameters.

        Args:
            event_handler (object, optional): An object with callback methods
                to handle various events. Defaults to None.
            metatrader_dir_path (str): Path to the MetaTrader directory.
            sleep_delay (float): Delay in seconds between file checks.
            max_retry_command_seconds (int): Maximum seconds to retry sending a command.
            load_orders_from_file (bool): Whether to load existing orders from file on startup.
            verbose (bool): If True, prints verbose output for debugging.
        """
        self.event_handler = event_handler
        self.sleep_delay = sleep_delay
        self.max_retry_command_seconds = max_retry_command_seconds
        self.load_orders_from_file = load_orders_from_file
        self.verbose = verbose
        self.command_id = 0

        # Verify that the MetaTrader directory exists
        if not exists(metatrader_dir_path):
            print('ERROR: metatrader_dir_path does not exist!')
            exit()

        # Define paths to various communication files
        self.path_orders = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Orders.txt')
        self.path_messages = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Messages.txt')
        self.path_market_data = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Market_Data.txt')
        self.path_bar_data = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Bar_Data.txt')
        self.path_historic_data = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Historic_Data.txt')
        self.path_historic_trades = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Historic_Trades.txt')
        self.path_orders_stored = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Orders_Stored.txt')
        self.path_messages_stored = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Messages_Stored.txt')
        self.path_commands_prefix = join(metatrader_dir_path, 'mql_stuff', 'mql_VS_Commands_')

        self.num_command_files = 50  # Number of command files to cycle through

        # Initialize internal state variables
        self._last_messages_millis = 0
        self._last_open_orders_str = ""
        self._last_messages_str = ""
        self._last_market_data_str = ""
        self._last_bar_data_str = ""
        self._last_historic_data_str = ""
        self._last_historic_trades_str = ""

        # Initialize data storage dictionaries
        self.open_orders = {}
        self.account_info = {}
        self.market_data = {}
        self.bar_data = {}
        self.historic_data = {}
        self.historic_trades = {}

        self._last_bar_data = {}
        self._last_market_data = {}

        # Control flags for thread execution
        self.ACTIVE = True
        self.START = False

        self.lock = Lock()  # Lock to synchronize command sending

        # Load existing messages and orders if configured
        self.load_messages()

        if self.load_orders_from_file:
            self.load_orders()

        # Start background threads for handling different types of data
        self.messages_thread = Thread(target=self.check_messages, args=())
        self.messages_thread.daemon = True
        self.messages_thread.start()

        self.market_data_thread = Thread(target=self.check_market_data, args=())
        self.market_data_thread.daemon = True
        self.market_data_thread.start()

        self.bar_data_thread = Thread(target=self.check_bar_data, args=())
        self.bar_data_thread.daemon = True
        self.bar_data_thread.start()

        self.open_orders_thread = Thread(target=self.check_open_orders, args=())
        self.open_orders_thread.daemon = True
        self.open_orders_thread.start()

        self.historic_data_thread = Thread(target=self.check_historic_data, args=())
        self.historic_data_thread.daemon = True
        self.historic_data_thread.start()

        self.reset_command_ids()  # Reset command IDs on initialization

        # Automatically start processing if no event handler is provided
        if self.event_handler is None:
            self.start()

    def start(self):
        """Sets the START flag to True, allowing threads to begin processing."""
        self.START = True

    def try_read_file(self, file_path):
        """
        Attempts to read the content of a file.

        Args:
            file_path (str): Path to the file to be read.

        Returns:
            str: Content of the file if successful, else an empty string.
        """
        try:
            if exists(file_path):
                with open(file_path) as f:
                    text = f.read()
                return text
        except (IOError, PermissionError):
            # Ignore these exceptions as they can occur during concurrent access
            pass
        except:
            # Print stack trace for any other unexpected exceptions
            print_exc()
        return ''

    def try_remove_file(self, file_path):
        """
        Attempts to remove a file, retrying up to 10 times on failure.

        Args:
            file_path (str): Path to the file to be removed.
        """
        for _ in range(10):
            try:
                os.remove(file_path)
                break  # Exit loop if removal is successful
            except (IOError, PermissionError):
                # Retry if file is temporarily inaccessible
                pass
            except:
                # Print stack trace for any other unexpected exceptions
                print_exc()

    def check_open_orders(self):
        """
        Continuously monitors the open orders file and triggers events on changes.

        This method runs in a separate thread and checks for updates to open orders.
        It updates internal state and invokes the event handler if there are any
        changes in the orders.
        """
        while self.ACTIVE:
            sleep(self.sleep_delay)

            if not self.START:
                continue  # Skip processing if not started

            text = self.try_read_file(self.path_orders)

            if len(text.strip()) == 0 or text == self._last_open_orders_str:
                continue  # No new data to process

            self._last_open_orders_str = text
            data = json.loads(text)

            new_event = False
            # Check for removed orders
            for order_id, order in self.open_orders.items():
                if order_id not in data['orders']:
                    new_event = True
                    if self.verbose:
                        print('Order removed: ', order)

            # Check for new orders
            for order_id, order in data['orders'].items():
                if order_id not in self.open_orders:
                    new_event = True
                    if self.verbose:
                        print('New order: ', order)

            self.account_info = data['account_info']
            self.open_orders = data['orders']

            # Optionally store the latest orders to file for persistence
            if self.load_orders_from_file:
                with open(self.path_orders_stored, 'w') as f:
                    f.write(json.dumps(data))

            # Trigger the event handler if there are any changes
            if self.event_handler is not None and new_event:
                self.event_handler.on_order_event()

    def check_messages(self):
        """
        Continuously monitors the messages file and triggers message events.

        This method runs in a separate thread and checks for new messages from MetaTrader.
        It updates internal state and invokes the event handler for each new message.
        """
        while self.ACTIVE:
            sleep(self.sleep_delay)

            if not self.START:
                continue  # Skip processing if not started

            text = self.try_read_file(self.path_messages)

            if len(text.strip()) == 0 or text == self._last_messages_str:
                continue  # No new messages to process

            self._last_messages_str = text
            data = json.loads(text)

            # Sort messages by timestamp to ensure chronological processing
            for millis, message in sorted(data.items()):
                if int(millis) > self._last_messages_millis:
                    self._last_messages_millis = int(millis)
                    # Invoke the message event handler
                    if self.event_handler is not None:
                        self.event_handler.on_message(message)

            # Optionally store the latest messages to file for persistence
            with open(self.path_messages_stored, 'w') as f:
                f.write(json.dumps(data))

    def check_market_data(self):
        """
        Continuously monitors the market data file and triggers tick events.

        This method runs in a separate thread and checks for updates to market data.
        It updates internal state and invokes the event handler for each tick update.
        """
        while self.ACTIVE:
            sleep(self.sleep_delay)

            if not self.START:
                continue  # Skip processing if not started

            text = self.try_read_file(self.path_market_data)

            if len(text.strip()) == 0 or text == self._last_market_data_str:
                continue  # No new market data to process

            self._last_market_data_str = text
            data = json.loads(text)

            self.market_data = data

            # Trigger tick events for symbols with updated bid/ask prices
            if self.event_handler is not None:
                for symbol in data.keys():
                    if (symbol not in self._last_market_data or
                            self.market_data[symbol] != self._last_market_data[symbol]):
                        self.event_handler.on_tick(
                            symbol,
                            self.market_data[symbol]['bid'],
                            self.market_data[symbol]['ask']
                        )
            self._last_market_data = data

    def check_bar_data(self):
        """
        Continuously monitors the bar data file and triggers bar data events.

        This method runs in a separate thread and checks for updates to bar data.
        It updates internal state and invokes the event handler for each new bar.
        """
        while self.ACTIVE:
            sleep(self.sleep_delay)

            if not self.START:
                continue  # Skip processing if not started

            text = self.try_read_file(self.path_bar_data)

            if len(text.strip()) == 0 or text == self._last_bar_data_str:
                continue  # No new bar data to process

            self._last_bar_data_str = text
            data = json.loads(text)

            self.bar_data = data

            # Trigger bar data events for symbols/timeframes with updated data
            if self.event_handler is not None:
                for st in data.keys():
                    if (st not in self._last_bar_data or
                            self.bar_data[st] != self._last_bar_data[st]):
                        symbol, time_frame = st.split('_')
                        self.event_handler.on_bar_data(
                            symbol,
                            time_frame,
                            self.bar_data[st]['time'],
                            self.bar_data[st]['open'],
                            self.bar_data[st]['high'],
                            self.bar_data[st]['low'],
                            self.bar_data[st]['close'],
                            self.bar_data[st]['tick_volume']
                        )
            self._last_bar_data = data

    def check_historic_data(self):
        """
        Continuously monitors the historic data and trades files and triggers corresponding events.

        This method runs in a separate thread and checks for updates to historic data and trades.
        It updates internal state and invokes the event handler for each new historic data or trade.
        """
        while self.ACTIVE:
            sleep(self.sleep_delay)

            if not self.START:
                continue  # Skip processing if not started

            # Check for historic data updates
            text = self.try_read_file(self.path_historic_data)

            if len(text.strip()) > 0 and text != self._last_historic_data_str:
                self._last_historic_data_str = text
                data = json.loads(text)

                for st in data.keys():
                    self.historic_data[st] = data[st]
                    if self.event_handler is not None:
                        symbol, time_frame = st.split('_')
                        self.event_handler.on_historic_data(
                            symbol, time_frame, data[st]
                        )

                # Remove the historic data file after processing
                self.try_remove_file(self.path_historic_data)

            # Check for historic trades updates
            text = self.try_read_file(self.path_historic_trades)

            if len(text.strip()) > 0 and text != self._last_historic_trades_str:
                self._last_historic_trades_str = text
                data = json.loads(text)

                self.historic_trades = data
                # Trigger the historic trades event handler
                self.event_handler.on_historic_trades()

                # Remove the historic trades file after processing
                self.try_remove_file(self.path_historic_trades)

    def load_orders(self):
        """
        Loads stored open orders from a file to restore state after a restart.
        """
        text = self.try_read_file(self.path_orders_stored)

        if len(text) > 0:
            self._last_open_orders_str = text
            data = json.loads(text)
            self.account_info = data['account_info']
            self.open_orders = data['orders']

    def load_messages(self):
        """
        Loads stored messages from a file to restore the last processed message timestamp.
        """
        text = self.try_read_file(self.path_messages_stored)

        if len(text) > 0:
            self._last_messages_str = text
            data = json.loads(text)

            # Update the last processed message timestamp
            for millis in data.keys():
                if int(millis) > self._last_messages_millis:
                    self._last_messages_millis = int(millis)

    def subscribe_symbols(self, symbols):
        """
        Subscribes to market (tick) data for specified symbols.

        Args:
            symbols (list[str]): List of symbol names to subscribe to.

        Returns:
            None

        The received market data will be stored in `self.market_data`, and the
        `event_handler.on_tick()` method will be triggered upon receiving data.
        """
        self.send_command('SUBSCRIBE_SYMBOLS', ','.join(symbols))

    def subscribe_symbols_bar_data(self, symbols=[['EURUSD', 'M1']]):
        """
        Subscribes to bar data for specified symbol and timeframe combinations.

        Args:
            symbols (list[list[str]]): List of [symbol, timeframe] pairs.
                Example: [['EURUSD', 'M1'], ['GBPUSD', 'H1']]

        Returns:
            None

        The received bar data will be stored in `self.bar_data`, and the
        `event_handler.on_bar_data()` method will be triggered upon receiving data.
        """
        # Format each symbol-timeframe pair as "Symbol,Timeframe"
        data = [f'{st[0]},{st[1]}' for st in symbols]
        self.send_command('SUBSCRIBE_SYMBOLS_BAR_DATA',
                          ','.join(str(p) for p in data))

    def get_historic_data(self,
                          symbol='EURUSD',
                          time_frame='D1',
                          start=(datetime.now(timezone.utc) -
                                 timedelta(days=30)).timestamp(),
                          end=datetime.now(timezone.utc).timestamp()):
        """
        Requests historic data for a specified symbol and timeframe within a time range.

        Args:
            symbol (str): The symbol for which to retrieve historic data.
            time_frame (str): The timeframe for the data (e.g., 'D1' for daily).
            start (int, optional): Start timestamp in seconds since epoch.
                Defaults to 30 days ago.
            end (int, optional): End timestamp in seconds since epoch.
                Defaults to the current time.

        Returns:
            None

        The received historic data will be stored in `self.historic_data`, and the
        `event_handler.on_historic_data()` method will be triggered upon receiving data.
        """
        # Prepare the data payload with symbol, timeframe, start, and end timestamps
        data = [symbol, time_frame, int(start), int(end)]
        self.send_command('GET_HISTORIC_DATA', ','.join(str(p) for p in data))

    def get_historic_trades(self, lookback_days=30):
        """
        Requests historic trade data for a specified lookback period.

        Args:
            lookback_days (int): Number of days to look back for trade history.
                The history must be visible in MetaTrader.

        Returns:
            None

        The received historic trades will be stored in `self.historic_trades`, and the
        `event_handler.on_historic_trades()` method will be triggered upon receiving data.
        """
        self.send_command('GET_HISTORIC_TRADES', str(lookback_days))

    def open_order(self, symbol='EURUSD',
                   order_type='buy',
                   lots=0.01,
                   price=0,
                   stop_loss=0,
                   take_profit=0,
                   magic=0,
                   comment='',
                   expiration=0):
        """
        Sends a command to open a new order with specified parameters.

        Args:
            symbol (str): Symbol for which to open the order.
            order_type (str): Type of order ('buy', 'sell', 'buylimit', 'selllimit',
                'buystop', 'sellstop').
            lots (float): Volume in lots.
            price (float): Price for the (pending) order. Use 0 for market orders.
            stop_loss (float): Stop loss price. Use 0 if no stop loss is needed.
            take_profit (float): Take profit price. Use 0 if no take profit is needed.
            magic (int): Magic number for the order.
            comment (str): Comment for the order.
            expiration (int): Expiration timestamp in seconds. Use 0 if no expiration.

        Returns:
            None
        """
        # Prepare the data payload with order parameters
        data = [symbol, order_type, lots, price, stop_loss,
                take_profit, magic, comment, expiration]
        self.send_command('OPEN_ORDER', ','.join(str(p) for p in data))

    def modify_order(self, ticket,
                     price=0,
                     stop_loss=0,
                     take_profit=0,
                     expiration=0):
        """
        Sends a command to modify an existing order.

        Args:
            ticket (int): Ticket number of the order to modify.
            price (float, optional): New price for the (pending) order. Only relevant for pending orders.
            stop_loss (float, optional): New stop loss price.
            take_profit (float, optional): New take profit price.
            expiration (int, optional): New expiration timestamp in seconds. Use 0 if no expiration.

        Returns:
            None
        """
        # Prepare the data payload with modification parameters
        data = [ticket, price, stop_loss, take_profit, expiration]
        self.send_command('MODIFY_ORDER', ','.join(str(p) for p in data))

    def close_order(self, ticket, lots=0):
        """
        Sends a command to close an existing order.

        Args:
            ticket (int): Ticket number of the order to close.
            lots (float, optional): Volume in lots to close. Use 0 to close the entire position.

        Returns:
            None
        """
        # Prepare the data payload with close parameters
        data = [ticket, lots]
        self.send_command('CLOSE_ORDER', ','.join(str(p) for p in data))

    def close_all_orders(self):
        """
        Sends a command to close all open orders.

        Returns:
            None
        """
        self.send_command('CLOSE_ALL_ORDERS', '')

    def close_orders_by_symbol(self, symbol):
        """
        Sends a command to close all orders associated with a specific symbol.

        Args:
            symbol (str): The symbol for which all associated orders should be closed.

        Returns:
            None
        """
        self.send_command('CLOSE_ORDERS_BY_SYMBOL', symbol)

    def close_orders_by_magic(self, magic):
        """
        Sends a command to close all orders associated with a specific magic number.

        Args:
            magic (str): The magic number for which all associated orders should be closed.

        Returns:
            None
        """
        self.send_command('CLOSE_ORDERS_BY_MAGIC', magic)

    def reset_command_ids(self):
        """
        Resets the internal command ID counter and notifies the MetaTrader side.

        This should be used when restarting the Python client without restarting MetaTrader.
        """
        self.command_id = 0  # Reset the command ID counter

        self.send_command("RESET_COMMAND_IDS", "")  # Notify MetaTrader to reset its command IDs

        sleep(0.5)  # Wait to ensure the reset command is processed before sending other commands

    def send_command(self, command, content):
        """
        Sends a command to the MetaTrader server by writing to one of the command files.

        Args:
            command (str): The command name to send.
            content (str): The content or parameters associated with the command.

        Returns:
            None

        This method handles command ID assignment, file selection for writing, and retries
        in case of file access issues. It ensures that commands are sent in chronological
        order without overwriting existing commands.
        """
        self.lock.acquire()  # Acquire lock to ensure thread-safe command sending

        self.command_id = (self.command_id + 1) % 100000  # Increment and wrap the command ID

        # Calculate the end time for retry attempts
        end_time = datetime.now(timezone.utc) + timedelta(seconds=self.max_retry_command_seconds)
        now = datetime.now(timezone.utc)

        # Retry loop in case all command files are occupied
        while now < end_time:
            success = False
            # Iterate through available command files to find an empty one
            for i in range(self.num_command_files):
                file_path = f'{self.path_commands_prefix}{i}.txt'
                if not exists(file_path):
                    try:
                        # Write the command to the selected file in the specified format
                        with open(file_path, 'w') as f:
                            f.write(f'<:{self.command_id}|{command}|{content}:>')
                        success = True
                        break  # Exit loop if command is successfully written
                    except:
                        # Print stack trace if writing fails and try the next file
                        print_exc()
            if success:
                break  # Exit retry loop if command was successfully sent
            sleep(self.sleep_delay)  # Wait before retrying
            now = datetime.now(timezone.utc)

        self.lock.release()  # Release the lock after attempting to send the command
