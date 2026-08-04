//+------------------------------------------------------------------+
//|                                                SessionGuard.mq4   |
//|   Time-based position guard for MetaTrader 4.                     |
//|   Closes positions at a configured time, blocks selected days,    |
//|   and flattens before the weekend.                                |
//|                                                                   |
//|   All logic runs on SERVER time, not terminal time.               |
//+------------------------------------------------------------------+
#property strict
#property description "Time and session guard - closes positions on schedule."

//--- Which orders this instance controls
enum ENUM_FILTER_MODE
{
   FILTER_ALL   = 0,   // All orders on this symbol
   FILTER_MAGIC = 1    // Only orders matching MagicFilter
};

//=== Inputs =========================================================
input string s0             = "--- SAFETY ---";
input bool   DryRun         = true;             // TRUE = log only, never close

input string s1             = "--- Order Filter ---";
input ENUM_FILTER_MODE FilterMode = FILTER_ALL; // Which orders to control
input int    MagicFilter    = 0;                // Magic number (if FILTER_MAGIC)

input string s2             = "--- Daily Close (server time) ---";
input bool   UseDailyClose  = false;            // Close everything once a day
input int    CloseHour      = 23;               // Hour, 0-23
input int    CloseMinute    = 45;               // Minute, 0-59

input string s3             = "--- Weekend Flat (server time) ---";
input bool   UseWeekendFlat = true;             // Close before the weekend
input int    FridayHour     = 22;               // Friday hour to flatten
input int    FridayMinute   = 30;               // Friday minute to flatten

input string s4             = "--- Blocked Days ---";
input bool   BlockSunday    = true;             // Sunday session
input bool   BlockMonday    = false;
input bool   BlockTuesday   = false;
input bool   BlockWednesday = false;
input bool   BlockThursday  = false;
input bool   BlockFriday    = false;

input string s5             = "--- Trading Window ---";
input bool   UseWindow      = false;            // Restrict to one time window
input int    WindowStartHr  = 14;               // Window start hour
input int    WindowStartMin = 30;               // Window start minute
input int    WindowEndHr    = 19;               // Window end hour
input int    WindowEndMin   = 0;                // Window end minute

input string s6             = "--- General ---";
input int    Slippage       = 30;               // Max slippage when closing
input bool   ShowPanel      = true;             // Draw status on the chart

//=== Globals ========================================================
datetime g_lastCloseRun  = 0;   // date on which the daily close already fired
datetime g_lastWeekendRun = 0;  // date on which the weekend flat already fired

//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidTime(CloseHour, CloseMinute))       return(ParamError("CloseHour/CloseMinute"));
   if(!ValidTime(FridayHour, FridayMinute))     return(ParamError("FridayHour/FridayMinute"));
   if(!ValidTime(WindowStartHr, WindowStartMin))return(ParamError("WindowStart"));
   if(!ValidTime(WindowEndHr, WindowEndMin))    return(ParamError("WindowEnd"));

   EventSetTimer(1);

   //--- Report the server/terminal offset once, so the user can sanity
   //--- check the numbers they typed against their own wall clock.
   int offsetHrs = (int)MathRound((TimeLocal() - TimeCurrent()) / 3600.0);

   Print("=== SessionGuard started === ", Symbol(),
         " | server=", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
         " | terminal=", TimeToString(TimeLocal(), TIME_DATE|TIME_MINUTES),
         " | terminal is server ", (offsetHrs >= 0 ? "+" : ""), offsetHrs, "h");

   if(DryRun)
      Print("DRY RUN is ON - the EA will log intended closes but will not close anything.");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   Print("=== SessionGuard stopped === reason=", reason);
}

//+------------------------------------------------------------------+
int ParamError(string which)
{
   Print("ERROR: invalid parameter - ", which);
   return(INIT_PARAMETERS_INCORRECT);
}

bool ValidTime(int h, int m)
{
   return(h >= 0 && h <= 23 && m >= 0 && m <= 59);
}

//+------------------------------------------------------------------+
//| Minutes since midnight, server time.                             |
//+------------------------------------------------------------------+
int MinutesOfDay(datetime t)
{
   return(TimeHour(t) * 60 + TimeMinute(t));
}

int ToMinutes(int h, int m)
{
   return(h * 60 + m);
}

//+------------------------------------------------------------------+
//| Is `mins` inside [start, end)?                                    |
//|                                                                   |
//| When end <= start the window wraps past midnight, and the test    |
//| flips from AND to OR. Writing this as a single AND is the most    |
//| common bug in time filters: 23:00-08:00 would never be true,      |
//| because no minute is both >= 1380 and < 480.                     |
//+------------------------------------------------------------------+
bool InRange(int mins, int startMins, int endMins)
{
   if(startMins == endMins) return(true);          // full day
   if(startMins < endMins)  return(mins >= startMins && mins < endMins);
   return(mins >= startMins || mins < endMins);    // wraps midnight
}

//+------------------------------------------------------------------+
//| Has this minute already been handled today?                      |
//|                                                                   |
//| The timer fires every second, so a bare "is it 23:45" test would  |
//| run sixty times. Storing the date of the last run makes the       |
//| action idempotent for the day.                                    |
//+------------------------------------------------------------------+
bool AlreadyRanToday(datetime lastRun)
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   return(lastRun == today);
}

datetime TodayStamp()
{
   return(StringToTime(TimeToString(TimeCurrent(), TIME_DATE)));
}

//+------------------------------------------------------------------+
bool IsDayBlocked(int dow)
{
   switch(dow)
   {
      case 0: return(BlockSunday);
      case 1: return(BlockMonday);
      case 2: return(BlockTuesday);
      case 3: return(BlockWednesday);
      case 4: return(BlockThursday);
      case 5: return(BlockFriday);
   }
   return(false);   // Saturday: market closed anyway
}

string DayName(int dow)
{
   string names[7] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   if(dow < 0 || dow > 6) return("?");
   return(names[dow]);
}

//+------------------------------------------------------------------+
//| True when new positions are permitted right now.                 |
//| Exported for other EAs to call, and shown on the panel.          |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   datetime now = TimeCurrent();

   if(IsDayBlocked(TimeDayOfWeek(now))) return(false);

   if(UseWindow)
   {
      int mins = MinutesOfDay(now);
      if(!InRange(mins,
                  ToMinutes(WindowStartHr, WindowStartMin),
                  ToMinutes(WindowEndHr,   WindowEndMin)))
         return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
bool IsMyOrder()
{
   if(OrderSymbol() != Symbol()) return(false);
   if(OrderType() != OP_BUY && OrderType() != OP_SELL) return(false);
   if(FilterMode == FILTER_MAGIC && OrderMagicNumber() != MagicFilter) return(false);
   return(true);
}

int CountMyOrders()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(IsMyOrder()) n++;
   }
   return(n);
}

//+------------------------------------------------------------------+
//| Close every matching position. Returns the number closed.        |
//|                                                                   |
//| Counts DOWN: closing an order re-indexes the pool, so an upward   |
//| loop silently skips the order that slides into the freed slot.    |
//+------------------------------------------------------------------+
int CloseAllMine(string reason)
{
   int closed = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsMyOrder()) continue;

      int    ticket = OrderTicket();
      double lots   = OrderLots();

      if(DryRun)
      {
         Print("DRY RUN | would close #", ticket,
               " ", DoubleToString(lots, 2), " lots | ", reason);
         closed++;
         continue;
      }

      bool ok = false;
      for(int attempt = 1; attempt <= 3 && !ok; attempt++)
      {
         RefreshRates();
         double price = (OrderType() == OP_BUY) ? Bid : Ask;
         price = NormalizeDouble(price, Digits);

         ok = OrderClose(ticket, lots, price, Slippage, clrNONE);

         if(!ok)
         {
            int err = GetLastError();
            if(err == 129 || err == 135 || err == 136 || err == 138)
            {
               Sleep(300);
               continue;              // transient: refresh and retry
            }
            Print("FAIL | close #", ticket, " | error=", err, " | ", reason);
            break;                    // permanent: stop retrying this ticket
         }
      }

      if(ok)
      {
         closed++;
         Print("OK | closed #", ticket,
               " ", DoubleToString(lots, 2), " lots | ", reason);
      }
   }
   return(closed);
}

//+------------------------------------------------------------------+
void CheckDailyClose()
{
   if(!UseDailyClose) return;
   if(AlreadyRanToday(g_lastCloseRun)) return;

   int nowMins    = MinutesOfDay(TimeCurrent());
   int targetMins = ToMinutes(CloseHour, CloseMinute);
   if(nowMins < targetMins) return;

   g_lastCloseRun = TodayStamp();

   string label = StringFormat("daily close %02d:%02d", CloseHour, CloseMinute);

   //--- Log the trigger itself, not just its consequences. A scheduled
   //--- action that stays silent when there is nothing to do is
   //--- indistinguishable from one that never ran.
   Print("DAILY CLOSE | trigger reached at ",
         StringFormat("%02d:%02d", nowMins / 60, nowMins % 60),
         " server | positions=", CountMyOrders());

   if(CountMyOrders() == 0)
   {
      Print("DAILY CLOSE | nothing to close");
      return;
   }

   int n = CloseAllMine(label);
   Print("DAILY CLOSE | ", n, " position(s) handled");
}

//+------------------------------------------------------------------+
void CheckWeekendFlat()
{
   if(!UseWeekendFlat) return;
   if(TimeDayOfWeek(TimeCurrent()) != 5) return;        // Friday only
   if(AlreadyRanToday(g_lastWeekendRun)) return;
   if(MinutesOfDay(TimeCurrent()) < ToMinutes(FridayHour, FridayMinute)) return;

   g_lastWeekendRun = TodayStamp();

   if(CountMyOrders() == 0) return;

   int n = CloseAllMine("weekend flat");
   Print("WEEKEND FLAT | ", n, " position(s) handled");
}

//+------------------------------------------------------------------+
void DrawPanel()
{
   if(!ShowPanel) { Comment(""); return; }

   datetime now = TimeCurrent();
   string status = IsTradingAllowed() ? "ALLOWED" : "BLOCKED";

   string txt = "SessionGuard" + (DryRun ? "  [DRY RUN]" : "") + "\n";
   txt += "Server time : " + TimeToString(now, TIME_DATE|TIME_MINUTES)
        + "  (" + DayName(TimeDayOfWeek(now)) + ")\n";
   txt += "Terminal    : " + TimeToString(TimeLocal(), TIME_MINUTES) + "\n";
   txt += "New trades  : " + status + "\n";
   txt += "Positions   : " + IntegerToString(CountMyOrders()) + "\n";

   if(UseWindow)
      txt += "Window      : " + StringFormat("%02d:%02d-%02d:%02d",
                WindowStartHr, WindowStartMin, WindowEndHr, WindowEndMin) + "\n";
   if(UseDailyClose)
      txt += "Daily close : " + StringFormat("%02d:%02d", CloseHour, CloseMinute)
           + (AlreadyRanToday(g_lastCloseRun) ? "  [done today]" : "  [armed]") + "\n";
   if(UseWeekendFlat)
      txt += "Weekend flat: Fri " + StringFormat("%02d:%02d", FridayHour, FridayMinute) + "\n";

   Comment(txt);
}

//+------------------------------------------------------------------+
void Run()
{
   CheckWeekendFlat();   // weekend rule wins over the daily rule
   CheckDailyClose();
   DrawPanel();
}

void OnTimer() { Run(); }
void OnTick()  { Run(); }
//+------------------------------------------------------------------+  