namespace Ses.Core;

public static class NoiseControl
{
    // Full wet avoids reintroducing unprocessed keyboard transients.
    // Optional expander attenuates residual quiet background without a hard gate.
    public static AudioSettings Strong(AudioSettings source)
    {
        var settings=source.Clone();
        settings.NoiseEnabled=true;settings.NoiseAutoEnabled=false;settings.NoiseMix=1;
        settings.SensitivityEnabled=true;settings.SensitivityAutoEnabled=true;
        settings.SensitivityMode=1;settings.SensitivityAttackMs=2;settings.SensitivityHoldMs=150;
        settings.SensitivityReleaseMs=120;settings.SensitivityHysteresisDb=6;
        settings.SensitivityRatio=2;settings.SensitivityMaxReductionDb=30;
        settings.Validate();return settings;
    }
}
