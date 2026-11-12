// ram-altman.exe - Windows console edition.
//
// Tracks RAM usage and, at most once a day, tells Sam Altman when this PC has
// RAM to spare. Same jokes, same CSV, same daily limit as the bash original,
// with Windows memory accounting.
//
// Built with the C# 5 compiler that ships with .NET Framework 4.x, so the
// resulting exe runs on any Windows 10/11 machine without a runtime install.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Net;
using System.Net.Mail;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace RamAltman
{
    internal sealed class Config
    {
        public string ConfigPath;
        public string To;
        public string From;
        public string FromName;
        public int Threshold;
        public string StateDir;
        public string SmtpHost;
        public int SmtpPort;
        public string SmtpUser;
        public string SmtpPassword;
        public bool SmtpTls;
        public string Sendmail;
        public string Outbox;
    }

    internal sealed class MemoryInfo
    {
        public long TotalKb;
        public long UsedKb;
        public long AvailableKb;
        public long FreeKb;
        public long CacheKb;
        public double Percent;

        public string TotalGib { get { return Program.FormatGib(TotalKb); } }
        public string UsedGib { get { return Program.FormatGib(UsedKb); } }
        public string AvailableGib { get { return Program.FormatGib(AvailableKb); } }
        public string FreeGib { get { return Program.FormatGib(FreeKb); } }
        public string CacheGib { get { return Program.FormatGib(CacheKb); } }
        public string PercentText { get { return Percent.ToString("0.0", CultureInfo.InvariantCulture); } }
    }

    internal sealed class Email
    {
        public string Subject;
        public string Body;
    }

    internal static class Program
    {
        private const string AppName = "ram-altman";
        private const string VersionNumber = "1.1.0";
        private const string TaskName = "Ram Altman";
        private const int MaxLogBytes = 10 * 1024 * 1024;
        private const int LogLinesToKeep = 50000;

        private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
        private static readonly Random Random = new Random();

        private static readonly string[] Subjects =
        {
            "Good news: we found some RAM",
            "Unused RAM detected in the wild",
            "RAM sighting on my PC",
            "{1} of RAM, just sitting there",
            "You missed a spot",
            "Daily RAM census: some survived",
            "{2}% of my RAM remains at large",
            "Still not all of it, I'm afraid"
        };

        private static readonly string[] Bodies =
        {
            "I'm writing to report that you appear to have missed some. This PC has {0} of RAM and {1} of it ({2}%) is currently available. I assume this is an oversight.",
            "A routine inspection of my PC found {1} of unclaimed RAM out of {0}. That's {2}% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it.",
            "Daily status report:\r\n\r\n  Total RAM:     {0}\r\n  Available:     {1} ({2}%)\r\n  Threat level:  someone at OpenAI might notice",
            "Even with every browser tab I own open, {1} of my {0} of RAM is still available. I'm as surprised as you are.",
            "Please don't be alarmed, but there is {1} of RAM on my desk that isn't in a data centre. That's {2}% of what's installed here, and as far as I can tell it has no plans today.",
            "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves {1} of {0} up for grabs.",
            "Today's forecast for my PC: clear skies, light workloads and {2}% available memory. Expect {1} of the installed {0} to stay idle through the evening.",
            "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on {1} of it. Total installed: {0}. It's not for sale, I just like knowing it's there.",
            "I have a confession. I have {1} of RAM that I'm not using, which is {2}% of the {0} in this PC. I've told nobody but you and a cron job.",
            "If {1} of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the {2}% of my memory with nothing to do."
        };

        private static readonly string[] Signoffs =
        {
            "Yours in abundance,",
            "Regards from the last free RAM in the county,",
            "Hoarding responsibly,",
            "Stay allocated,",
            "Yours, with memory to spare,",
            "Kind regards,"
        };

        private static int Main(string[] args)
        {
            try
            {
                return Run(args);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(AppName + ": " + ex.Message);
                return 1;
            }
        }

        private static int Run(string[] args)
        {
            string command = args.Length > 0 ? args[0].ToLowerInvariant() : "";

            if (command == "--help" || command == "-h" || command == "-?" || command == "/?")
            {
                ShowHelp();
                return 0;
            }

            if (command == "--version")
            {
                Console.WriteLine(AppName + " " + VersionNumber);
                return 0;
            }

            if (command == "--install-task")
            {
                InstallTask();
                return 0;
            }

            if (command == "--uninstall-task")
            {
                UninstallTask();
                return 0;
            }

            Config config = LoadConfig();

            if (command == "--status")
            {
                MemoryInfo statusMemory = ReadMemory();
                ShowStatus(statusMemory);
                return 0;
            }

            if (command == "--dry-run")
            {
                MemoryInfo dryMemory = ReadMemory();
                ShowStatus(dryMemory);
                if (!IsOverThreshold(dryMemory, config.Threshold))
                {
                    Console.WriteLine("No email: available RAM is not above " + config.Threshold + "%.");
                    return 0;
                }

                Email dryEmail = ComposeEmail(config, dryMemory, true);
                Config preview = new Config();
                preview.From = string.IsNullOrWhiteSpace(config.From) ? "sender-not-set@example.com" : config.From;
                preview.To = string.IsNullOrWhiteSpace(config.To) ? "recipient-not-set@example.com" : config.To;
                preview.FromName = config.FromName;
                Console.WriteLine();
                Console.WriteLine(RenderMessage(preview, dryEmail));
                return 0;
            }

            if (command.Length != 0)
            {
                throw new Exception("unknown option: " + command + " (try --help)");
            }

            if (string.IsNullOrWhiteSpace(config.To)) throw new Exception("recipient is not set (to / RAM_ALTMAN_TO)");
            if (string.IsNullOrWhiteSpace(config.From)) throw new Exception("sender is not set (from / RAM_ALTMAN_FROM)");

            Directory.CreateDirectory(config.StateDir);

            FileStream lockStream = AcquireLock(config.StateDir);
            if (lockStream == null) return 0;

            try
            {
                MemoryInfo memory = ReadMemory();
                LogSample(config, memory);

                if (!IsOverThreshold(memory, config.Threshold)) return 0;

                string today = DateTime.Now.ToString("yyyy-MM-dd", Invariant);
                string lastSentPath = Path.Combine(config.StateDir, "last_sent");
                string lastSent = File.Exists(lastSentPath) ? File.ReadAllText(lastSentPath).Trim() : "";
                if (lastSent == today) return 0;

                Email email = ComposeEmail(config, memory, false);
                SendEmail(config, email);

                File.WriteAllText(lastSentPath, today);
                return 0;
            }
            finally
            {
                lockStream.Dispose();
            }
        }

        // ----- configuration -------------------------------------------------

        private static Config LoadConfig()
        {
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string defaultStateDir = Path.Combine(localAppData, "ram-altman");

            string configPath = Environment.GetEnvironmentVariable("RAM_ALTMAN_CONFIG");
            if (string.IsNullOrWhiteSpace(configPath))
            {
                configPath = Path.Combine(defaultStateDir, "config.ini");
            }

            Dictionary<string, string> ini = ReadIni(configPath);

            Config config = new Config();
            config.ConfigPath = configPath;
            config.StateDir = GetAbsolutePath(GetValue(ini, "statedir", "RAM_ALTMAN_STATE_DIR", defaultStateDir));
            config.To = GetValue(ini, "to", "RAM_ALTMAN_TO", "");
            config.From = GetValue(ini, "from", "RAM_ALTMAN_FROM", "");
            config.FromName = GetValue(ini, "fromname", "RAM_ALTMAN_FROM_NAME", "");
            config.Threshold = ParseRange(GetValue(ini, "threshold", "RAM_ALTMAN_THRESHOLD", "10"), 0, 100, "threshold");
            config.SmtpHost = GetValue(ini, "smtphost", "RAM_ALTMAN_SMTP_HOST", "");
            config.SmtpPort = ParseRange(GetValue(ini, "smtpport", "RAM_ALTMAN_SMTP_PORT", "587"), 1, 65535, "smtpPort");
            config.SmtpUser = GetValue(ini, "smtpuser", "RAM_ALTMAN_SMTP_USER", "");
            config.SmtpPassword = GetValue(ini, "smtppassword", "RAM_ALTMAN_SMTP_PASSWORD", "");
            config.Sendmail = GetValue(ini, "sendmail", "RAM_ALTMAN_SENDMAIL", "");
            config.Outbox = GetValue(ini, "outbox", "RAM_ALTMAN_OUTBOX", "");

            string tls = GetValue(ini, "smtptls", "RAM_ALTMAN_SMTP_TLS", "true").Trim().ToLowerInvariant();
            config.SmtpTls = !(tls == "false" || tls == "0" || tls == "no" || tls == "off");

            return config;
        }

        private static Dictionary<string, string> ReadIni(string path)
        {
            Dictionary<string, string> ini = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(path)) return ini;

            foreach (string line in File.ReadAllLines(path))
            {
                string trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed[0] == '#' || trimmed[0] == ';') continue;
                int equals = trimmed.IndexOf('=');
                if (equals < 1) continue;

                string key = trimmed.Substring(0, equals).Trim();
                string value = trimmed.Substring(equals + 1).Trim();
                if (value.Length >= 2)
                {
                    char first = value[0];
                    char last = value[value.Length - 1];
                    if ((first == '"' && last == '"') || (first == '\'' && last == '\''))
                    {
                        value = value.Substring(1, value.Length - 2);
                    }
                }
                if (key.Length > 0) ini[key] = value;
            }
            return ini;
        }

        private static string GetValue(Dictionary<string, string> ini, string key, string envName, string defaultValue)
        {
            string env = Environment.GetEnvironmentVariable(envName);
            if (!string.IsNullOrWhiteSpace(env)) return env.Trim();

            string value;
            if (ini.TryGetValue(key, out value) && !string.IsNullOrWhiteSpace(value)) return value.Trim();
            return defaultValue;
        }

        private static string GetAbsolutePath(string path)
        {
            if (Path.IsPathRooted(path)) return path;
            return Path.Combine(Directory.GetCurrentDirectory(), path);
        }

        private static int ParseRange(string text, int min, int max, string name)
        {
            int value;
            if (!int.TryParse(text, NumberStyles.Integer, Invariant, out value) || value < min || value > max)
            {
                throw new Exception(name + " must be a number between " + min + " and " + max + " (got '" + text + "')");
            }
            return value;
        }

        // ----- memory --------------------------------------------------------

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private sealed class MemoryStatusEx
        {
            public uint Length;
            public uint MemoryLoad;
            public ulong TotalPhys;
            public ulong AvailPhys;
            public ulong TotalPageFile;
            public ulong AvailPageFile;
            public ulong TotalVirtual;
            public ulong AvailVirtual;
            public ulong AvailExtendedVirtual;

            public MemoryStatusEx()
            {
                Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
            }
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MemoryStatusEx buffer);

        private static MemoryInfo ReadMemory()
        {
            long totalKb;
            long availableKb;
            long freeKb = 0;

            string fake = Environment.GetEnvironmentVariable("RAM_ALTMAN_FAKE_MEMORY");
            if (!string.IsNullOrWhiteSpace(fake))
            {
                string[] parts = fake.Split(',');
                if (parts.Length < 2) throw new Exception("RAM_ALTMAN_FAKE_MEMORY must be totalKb,availableKb[,freeKb]");
                if (!long.TryParse(parts[0].Trim(), NumberStyles.Integer, Invariant, out totalKb) || totalKb <= 0)
                {
                    throw new Exception("RAM_ALTMAN_FAKE_MEMORY has an invalid total");
                }
                if (!long.TryParse(parts[1].Trim(), NumberStyles.Integer, Invariant, out availableKb))
                {
                    throw new Exception("RAM_ALTMAN_FAKE_MEMORY has an invalid available figure");
                }
                if (parts.Length >= 3 && parts[2].Trim().Length > 0)
                {
                    long.TryParse(parts[2].Trim(), NumberStyles.Integer, Invariant, out freeKb);
                }
            }
            else
            {
                MemoryStatusEx status = new MemoryStatusEx();
                if (!GlobalMemoryStatusEx(status))
                {
                    throw new Exception("GlobalMemoryStatusEx failed (error " + Marshal.GetLastWin32Error() + ")");
                }
                totalKb = (long)(status.TotalPhys / 1024UL);
                availableKb = (long)(status.AvailPhys / 1024UL);

                try
                {
                    using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
                        "SELECT FreeAndZeroPageListBytes FROM Win32_PerfRawData_PerfOS_Memory"))
                    {
                        foreach (ManagementBaseObject item in searcher.Get())
                        {
                            freeKb = (long)(Convert.ToUInt64(item["FreeAndZeroPageListBytes"], Invariant) / 1024UL);
                        }
                    }
                }
                catch (ManagementException)
                {
                    freeKb = 0;
                }
            }

            if (totalKb <= 0) throw new Exception("could not read total physical memory");
            if (availableKb > totalKb) availableKb = totalKb;
            if (availableKb < 0) availableKb = 0;
            if (freeKb > availableKb) freeKb = availableKb;
            if (freeKb < 0) freeKb = 0;

            MemoryInfo memory = new MemoryInfo();
            memory.TotalKb = totalKb;
            memory.AvailableKb = availableKb;
            memory.UsedKb = totalKb - availableKb;
            memory.FreeKb = freeKb;
            memory.CacheKb = availableKb - freeKb;
            memory.Percent = Math.Round(availableKb * 100.0 / totalKb, 1);
            return memory;
        }

        public static string FormatGib(long kb)
        {
            double gib = Math.Round(kb / 1048576.0, 1);
            return gib.ToString("0.0", Invariant) + " GiB";
        }

        private static void ShowStatus(MemoryInfo memory)
        {
            Console.WriteLine("Total:      " + memory.TotalGib);
            Console.WriteLine("Used:       " + memory.UsedGib);
            Console.WriteLine("Available:  " + memory.AvailableGib + " (" + memory.PercentText + "%)");
            Console.WriteLine("  Free:     " + memory.FreeGib);
            Console.WriteLine("  Cache:    " + memory.CacheGib);
        }

        private static bool IsOverThreshold(MemoryInfo memory, int threshold)
        {
            return memory.AvailableKb * 100L > (long)threshold * memory.TotalKb;
        }

        // ----- email ---------------------------------------------------------

        private static Email ComposeEmail(Config config, MemoryInfo memory, bool dryRun)
        {
            int subjectIndex = Pick(config, "subject", Subjects.Length, dryRun);
            int bodyIndex = Pick(config, "body", Bodies.Length, dryRun);
            int signoffIndex = Pick(config, "signoff", Signoffs.Length, dryRun);

            string total = memory.TotalGib;
            string available = memory.AvailableGib;
            string pct = memory.PercentText;

            string subject = string.Format(Invariant, Subjects[subjectIndex], total, available, pct);
            string bodyText = string.Format(Invariant, Bodies[bodyIndex], total, available, pct);
            string signoff = Signoffs[signoffIndex];
            string fromName = string.IsNullOrWhiteSpace(config.FromName) ? "A concerned RAM owner" : config.FromName;

            Email email = new Email();
            email.Subject = subject;
            email.Body =
                "Hi Sam,\r\n\r\n" + bodyText + "\r\n\r\n" + signoff + "\r\n" + fromName + "\r\n\r\n" +
                "--\r\nSent automatically, at most once a day, by a small script on one PC.\r\n" +
                "Reply if you'd like it to stop.";
            return email;
        }

        private static int Pick(Config config, string name, int count, bool dryRun)
        {
            if (dryRun || count <= 1) return Random.Next(count);

            string bagPath = Path.Combine(config.StateDir, "bag_" + name);
            string lastPath = bagPath + ".last";

            if (!File.Exists(bagPath) || new FileInfo(bagPath).Length == 0)
            {
                List<int> items = new List<int>();
                for (int i = 0; i < count; i++) items.Add(i);
                Shuffle(items);

                if (File.Exists(lastPath) && items.Count > 1)
                {
                    string last = File.ReadAllText(lastPath).Trim();
                    if (items[0].ToString(Invariant) == last)
                    {
                        int first = items[0];
                        items.RemoveAt(0);
                        items.Add(first);
                    }
                }

                List<string> text = new List<string>();
                foreach (int item in items) text.Add(item.ToString(Invariant));
                File.WriteAllLines(bagPath, text.ToArray());
            }

            List<string> queue = new List<string>();
            foreach (string line in File.ReadAllLines(bagPath))
            {
                if (line.Length > 0) queue.Add(line);
            }
            if (queue.Count == 0) return Random.Next(count);

            int next = int.Parse(queue[0], Invariant);
            queue.RemoveAt(0);
            File.WriteAllLines(bagPath, queue.ToArray());
            File.WriteAllText(lastPath, next.ToString(Invariant));

            if (next >= count) next = Random.Next(count);
            return next;
        }

        private static void Shuffle(List<int> items)
        {
            for (int i = items.Count - 1; i > 0; i--)
            {
                int j = Random.Next(i + 1);
                int tmp = items[i];
                items[i] = items[j];
                items[j] = tmp;
            }
        }

        private static string RenderMessage(Config config, Email email)
        {
            string from = string.IsNullOrWhiteSpace(config.FromName)
                ? config.From
                : config.FromName + " <" + config.From + ">";
            string date = DateTimeOffset.Now.ToString("ddd, dd MMM yyyy HH:mm:ss zzz", Invariant);

            StringBuilder builder = new StringBuilder();
            builder.Append("From: ").Append(from).Append("\r\n");
            builder.Append("To: ").Append(config.To).Append("\r\n");
            builder.Append("Subject: ").Append(email.Subject).Append("\r\n");
            builder.Append("Date: ").Append(date).Append("\r\n");
            builder.Append("MIME-Version: 1.0\r\n");
            builder.Append("Content-Type: text/plain; charset=UTF-8\r\n");
            builder.Append("Auto-Submitted: auto-generated\r\n");
            builder.Append("\r\n");
            builder.Append(email.Body);
            return builder.ToString();
        }

        private static void SendEmail(Config config, Email email)
        {
            string message = RenderMessage(config, email);

            if (!string.IsNullOrWhiteSpace(config.Outbox))
            {
                string directory = Path.GetDirectoryName(config.Outbox);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                File.WriteAllText(config.Outbox, message, new UTF8Encoding(false));
                return;
            }

            if (!string.IsNullOrWhiteSpace(config.Sendmail))
            {
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = Environment.GetEnvironmentVariable("ComSpec");
                info.Arguments = "/d /c " + config.Sendmail;
                info.UseShellExecute = false;
                info.RedirectStandardInput = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                info.CreateNoWindow = true;

                using (Process process = Process.Start(info))
                {
                    process.StandardInput.Write(message);
                    process.StandardInput.Close();
                    string stderr = process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        throw new Exception("sendmail command exited with " + process.ExitCode + ": " + stderr.Trim());
                    }
                }
                return;
            }

            if (string.IsNullOrWhiteSpace(config.SmtpHost))
            {
                throw new Exception("no mail transport configured: set smtpHost/smtpUser/smtpPassword, set sendmail, or set outbox");
            }

            using (MailMessage mail = new MailMessage())
            {
                mail.From = new MailAddress(config.From, config.FromName);
                mail.To.Add(config.To);
                mail.Subject = email.Subject;
                mail.Body = email.Body;
                mail.BodyEncoding = Encoding.UTF8;
                mail.Headers["Auto-Submitted"] = "auto-generated";

                using (SmtpClient client = new SmtpClient(config.SmtpHost, config.SmtpPort))
                {
                    client.EnableSsl = config.SmtpTls;
                    client.Timeout = 30000;
                    if (!string.IsNullOrWhiteSpace(config.SmtpUser))
                    {
                        client.Credentials = new NetworkCredential(config.SmtpUser, config.SmtpPassword);
                    }
                    client.Send(mail);
                }
            }
        }

        // ----- state ---------------------------------------------------------

        private static void LogSample(Config config, MemoryInfo memory)
        {
            string logPath = Path.Combine(config.StateDir, "usage.csv");
            UTF8Encoding encoding = new UTF8Encoding(false);

            if (!File.Exists(logPath))
            {
                File.AppendAllText(logPath, "timestamp,total_kb,used_kb,available_kb,available_pct\r\n", encoding);
            }

            string timestamp = DateTimeOffset.Now.ToString("yyyy-MM-ddTHH:mm:sszzz", Invariant);
            string line = string.Join(",", new string[]
            {
                timestamp,
                memory.TotalKb.ToString(Invariant),
                memory.UsedKb.ToString(Invariant),
                memory.AvailableKb.ToString(Invariant),
                memory.PercentText
            });
            File.AppendAllText(logPath, line + "\r\n", encoding);

            if (new FileInfo(logPath).Length > MaxLogBytes)
            {
                string[] lines = File.ReadAllLines(logPath);
                List<string> trimmed = new List<string>();
                trimmed.Add(lines[0]);
                int start = lines.Length > LogLinesToKeep ? lines.Length - LogLinesToKeep : 1;
                for (int i = start; i < lines.Length; i++) trimmed.Add(lines[i]);
                File.WriteAllLines(logPath, trimmed.ToArray(), encoding);
            }
        }

        private static FileStream AcquireLock(string stateDir)
        {
            string lockPath = Path.Combine(stateDir, "lock");
            try
            {
                return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException)
            {
                return null;
            }
        }

        // ----- Task Scheduler ------------------------------------------------

        private static string CurrentExecutable()
        {
            return Process.GetCurrentProcess().MainModule.FileName;
        }

        private static void InstallTask()
        {
            string exe = CurrentExecutable();
            string taskCommand = "\"" + exe + "\"";
            string arguments = "/Create /F /SC MINUTE /MO 5 /TN \"" + TaskName + "\" /TR \"" +
                taskCommand.Replace("\"", "\\\"") + "\"";

            RunProcess("schtasks.exe", arguments);
            Console.WriteLine("Scheduled task '" + TaskName + "' created: every 5 minutes, runs " + exe);
            Console.WriteLine("Undo with: " + exe + " --uninstall-task");
        }

        private static void UninstallTask()
        {
            RunProcess("schtasks.exe", "/Delete /F /TN \"" + TaskName + "\"");
            Console.WriteLine("Scheduled task '" + TaskName + "' removed.");
        }

        private static void RunProcess(string fileName, string arguments)
        {
            ProcessStartInfo info = new ProcessStartInfo(fileName, arguments);
            info.UseShellExecute = false;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.CreateNoWindow = true;

            using (Process process = Process.Start(info))
            {
                string stdout = process.StandardOutput.ReadToEnd();
                string stderr = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new Exception(fileName + " failed: " + (stderr + stdout).Trim());
                }
                if (stdout.Trim().Length > 0) Console.WriteLine(stdout.Trim());
            }
        }

        // ----- help ----------------------------------------------------------

        private static void ShowHelp()
        {
            Console.WriteLine(AppName + " " + VersionNumber + " - Windows console edition");
            Console.WriteLine();
            Console.WriteLine("Tracks RAM usage and, at most once a day, tells Sam Altman when this PC");
            Console.WriteLine("has RAM to spare.");
            Console.WriteLine();
            Console.WriteLine("Usage:");
            Console.WriteLine("  ram-altman.exe                 Log a sample and send the daily email if due");
            Console.WriteLine("  ram-altman.exe --status        Print current memory figures and exit");
            Console.WriteLine("  ram-altman.exe --dry-run       Print the email that would be sent and exit");
            Console.WriteLine("  ram-altman.exe --install-task  Sample every 5 minutes in Task Scheduler");
            Console.WriteLine("  ram-altman.exe --uninstall-task Remove that scheduled task");
            Console.WriteLine("  ram-altman.exe --version       Print the version");
            Console.WriteLine("  ram-altman.exe --help          Show this help");
            Console.WriteLine();
            Console.WriteLine("Configuration:");
            Console.WriteLine("  Reads config.ini from %LOCALAPPDATA%\\ram-altman\\config.ini, or from");
            Console.WriteLine("  RAM_ALTMAN_CONFIG. Every setting can also be set with a RAM_ALTMAN_*");
            Console.WriteLine("  environment variable. See windows\\config.example.ini.");
            Console.WriteLine();
            Console.WriteLine("  Emails go through SMTP (smtpHost/smtpUser/smtpPassword), an external");
            Console.WriteLine("  sendmail-compatible command, or a file if outbox is set. --dry-run needs");
            Console.WriteLine("  no mail settings at all.");
            Console.WriteLine();
            Console.WriteLine("State:");
            Console.WriteLine("  Samples are appended to usage.csv in the state directory");
            Console.WriteLine("  (%LOCALAPPDATA%\\ram-altman by default). The last send date lives there");
            Console.WriteLine("  too, so a failed send is retried on the next run.");
        }
    }
}
