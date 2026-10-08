namespace Ses.Core;

// Pure policy: registry access and file-version lookup remain with the desktop caller.
public static class StartupRegistration
{
    private const string Suffix = "\" --minimized";

    public static bool TryGetTarget(string? savedCommand, out string target)
    {
        target = "";
        if (savedCommand is null || savedCommand.Length <= Suffix.Length + 1 || !savedCommand.StartsWith('"') ||
            !savedCommand.EndsWith(Suffix, StringComparison.Ordinal)) return false;
        string candidate = savedCommand[1..^Suffix.Length];
        if (!IsLocalExecutable(candidate)) return false;
        target = candidate;
        return true;
    }

    public static string? TryUpgrade(string? savedCommand, string currentExecutable,
        Version? savedVersion, Version? currentVersion)
    {
        if (!TryGetTarget(savedCommand, out string savedExecutable) ||
            !IsLocalExecutable(currentExecutable) || savedVersion is null || currentVersion is null ||
            string.Equals(savedExecutable, currentExecutable, StringComparison.OrdinalIgnoreCase) ||
            Normalize(savedVersion) > Normalize(currentVersion)) return null;
        return "\"" + currentExecutable + Suffix;
    }

    private static Version Normalize(Version version) =>
        new(version.Major, version.Minor, Math.Max(0, version.Build), Math.Max(0, version.Revision));

    private static bool IsLocalExecutable(string? path)
    {
        // Do not probe UNC shares, device namespaces, shell expressions or alternate data streams.
        if (string.IsNullOrEmpty(path) || path.Length < 10 ||
            !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\' ||
            !Path.IsPathFullyQualified(path) ||
            !(string.Equals(Path.GetFileName(path), "Veylo.exe", StringComparison.OrdinalIgnoreCase) ||
              string.Equals(Path.GetFileName(path), "SES.exe", StringComparison.OrdinalIgnoreCase))) return false;
        foreach (char character in path.AsSpan(2))
            if (char.IsControl(character) || character is '"' or ':' or '/' or '<' or '>' or '|' or '?' or '*') return false;
        foreach (string segment in path[3..].Split('\\'))
            if (segment.Length == 0 || segment.EndsWith(' ') || segment.EndsWith('.')) return false;
        return true;
    }
}
