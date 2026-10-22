# Escape From Granny — iOS bulut derlemesi

Unity'nin (Windows) dışa aktardığı Xcode projesi, GitHub Actions'ın macOS makinesinde (Xcode 26) derlenir,
App Store Connect API anahtarıyla imzalanır ve **TestFlight'a** yüklenir. Mac gerekmez.

**Oyun dosyaları şifrelidir.** `export/` klasöründeki parçalar AES-256 (OpenSSL, PBKDF2-SHA256, 600.000 tur)
ile şifrelenmiştir ve bütünlükleri HMAC-SHA256 ile doğrulanır. Anahtar yalnızca bu reponun gizli
`EXPORT_KEY` secret'ında ve geliştiricinin bilgisayarında bulunur; derleme sırasında makinede açılır ve iş bitince silinir.

## Gerekli secret'lar (Settings → Secrets and variables → Actions)

| Ad | Değer |
|---|---|
| `EXPORT_KEY` | Şifre çözme anahtarı (`Builds/EXPORT_KEY.txt`) |
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_KEY_P8` | `AuthKey_XXXX.p8` dosyasının tüm metni |

API anahtarı: App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**, erişim **Admin**.

## Çalıştırma

Actions → **iOS -> TestFlight** → *Run workflow*. Makine kuyrukta uzun beklerse başka bir `runner` seçin.
Build numarası boş bırakılırsa `100 + çalıştırma no` olur.

## Yeni sürüm

1. Unity: *Escape From Granny → Store → iOS: Export Xcode Project + Zip for Cloud Build* (`Builds/iOS_zip/`).
2. Parçaları birleştirip şifreleyin ve 90 MB'lık parçalara bölün:
   ```sh
   cat efg_ios.zip.0* > efg_ios.zip
   shasum -a 256 efg_ios.zip | cut -d' ' -f1 > efg_ios.zip.sha256
   openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -salt -in efg_ios.zip -out efg_ios.zip.enc -pass file:EXPORT_KEY.txt
   split -b 94371840 -d -a 3 --numeric-suffixes=1 efg_ios.zip.enc efg_ios.zip.enc.
   ```
   HMAC dosyası: `ci/build.sh` içindeki doğrulama ile aynı yöntem (PBKDF2 "efg-export-mac", 200.000 tur).
3. `export/` klasörüne koyup `main`e gönderin → iş akışı kendiliğinden başlar.
