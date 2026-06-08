using FullSerializer;
using Microsoft.Xna.Framework;
using System.Collections.Generic;
using Terraria;
using Terraria.Audio;
using Terraria.ModLoader;

namespace TF2HitSystem
{
    public class TF2CriticalEffect : ModPlayer
    {
        public static SoundStyle CritSound;
        private static List<CritTextInfo> critTexts = new List<CritTextInfo>();

        public override void Load()
        {
            if (!Main.dedServ)
            {
                TF2Config config = ModContent.GetInstance<TF2Config>();

                CritSound = new SoundStyle("Tf2CritEffect/Sounds/CritSounds/hit-sound-1")
                {
                    Volume = config.CritSoundVolume,
                    PitchVariance = 0.0f,
                    MaxInstances = 20
                };
            }
        }


        public override void OnHitNPC(NPC target, NPC.HitInfo hit, int damageDone)
        {
            if (hit.Crit)
            {
                SoundEngine.PlaySound(CritSound, target.Center);
            }
            else
            {
                PlayRandomHitSound(target.Center);
            }

            ModifyLatestCombatText(hit.Crit, damageDone);

            if (hit.Crit)
            {
                Vector2 position = target.position;
                position.Y -= 40;
                int critTextIndex = CombatText.NewText(target.Hitbox, new Color(50, 205, 50), "CRITICAL HIT!!!", true, false);
                if (critTextIndex != -1)
                {
                    critTexts.Add(new CritTextInfo(critTextIndex, 120, true, false));
                }
            }

            base.OnHitNPC(target, hit, damageDone);
        }

        private void ModifyLatestCombatText(bool isCrit, int damageDone)
        {
            for (int i = Main.combatText.Length - 1; i >= 0; i--)
            {
                CombatText ct = Main.combatText[i];
                if (ct.active && ct.text == damageDone.ToString())
                {
                    ct.text = $"-{ct.text}";
                    critTexts.Add(new CritTextInfo(i, 90, false, true));
                    break;
                }
            }
        }

        public override void PostUpdate()
        {
            for (int i = critTexts.Count - 1; i >= 0; i--)
            {
                CritTextInfo info = critTexts[i];

                // Check if the index is within bounds of the Main.combatText array
                if (info.Index >= 0 && info.Index < Main.combatText.Length)
                {
                    CombatText ct = Main.combatText[info.Index];

                    if (info.IsCriticalHitText && ct.lifeTime < info.InitialLifeTime - 60)
                    {
                        float progress = (float)(info.InitialLifeTime - 60 - ct.lifeTime) / (info.InitialLifeTime - 60);
                        ct.color = Color.Lerp(new Color(50, 205, 50), Color.Red, progress);
                        ct.alpha = progress;
                    }
                    else if (info.IsDamageNumber && ct.lifeTime < 30)
                    {
                        ct.active = false;
                    }

                    if (!ct.active)
                    {
                        critTexts.RemoveAt(i); // Remove the item safely
                    }
                }
                else
                {
                    // Invalid index, remove from the list
                    critTexts.RemoveAt(i);
                }
            }
        }



        private struct CritTextInfo
        {
            public int Index;
            public int InitialLifeTime;
            public bool IsCriticalHitText;
            public bool IsDamageNumber;

            public CritTextInfo(int index, int initialLifeTime, bool isCriticalHitText, bool isDamageNumber)
            {
                Index = index;
                InitialLifeTime = initialLifeTime;
                IsCriticalHitText = isCriticalHitText;
                IsDamageNumber = isDamageNumber;
            }
        }

        private void PlayRandomHitSound(Vector2 position)
        {
            TF2Config config = ModContent.GetInstance<TF2Config>();
            HitSoundOptions hitSoundType = config.GetHitSoundType();

            // If hit sound is set to Off, do not play any sound
            if (hitSoundType == HitSoundOptions.Off) return;

            // Convert the enum to a string for file path construction
            string hitSoundSubfolder = hitSoundType.ToString().ToLowerInvariant();

            // Retrieve the count of available hit sounds for the selected type
            int count = GetHitSoundFileCount(hitSoundSubfolder);

            if (count > 0)
            {
                // Construct file name based on random selection
                string fileName = hitSoundSubfolder == "default" ? "hit-sound-1" : $"hit-sound-{Main.rand.Next(1, count + 1)}";
                string path = $"Tf2CritEffect/Sounds/HitSounds/{hitSoundSubfolder}/{fileName}";

                // Check if the asset exists and play the sound
                if (ModContent.HasAsset(path))
                {
                    SoundStyle hitSound = new SoundStyle(path)
                    {
                        Volume = config.HitSoundVolume,
                        PitchVariance = 0.0f,
                        MaxInstances = 20
                    };
                    SoundEngine.PlaySound(hitSound, position);
                }
            }
        }




        private int GetHitSoundFileCount(string subfolder)
        {
            switch (subfolder.ToLowerInvariant())
            {
                case "electro": return 3;
                case "notes": return 10;
                case "percussion": return 5;
                case "retro": return 5;
                case "vortex": return 5;
                default: return 1;
            }
        }
    }
}
