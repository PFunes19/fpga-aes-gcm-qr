"""Descifra el texto Base64 leido del QR de la demo DE10-Lite.

Uso:  python decrypt_qr.py <texto_base64_de_60_caracteres>
Requiere:  pip install cryptography

Paquete: nonce (12 bytes) | cifrado (16) | etiqueta GCM (16), sin AAD.
La clave es la clave publica de prueba de de10lite_top (DEMO_KEY).
"""
import base64
import sys

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

DEMO_KEY = bytes.fromhex("000102030405060708090a0b0c0d0e0f")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    text = sys.argv[1].strip()
    packet = base64.b64decode(text, validate=True)
    if len(packet) != 44:
        sys.exit(f"Se esperaban 44 bytes y llegaron {len(packet)}")
    nonce, ciphertext, tag = packet[:12], packet[12:28], packet[28:]
    plaintext = AESGCM(DEMO_KEY).decrypt(nonce, ciphertext + tag, None)
    print("nonce   :", nonce.hex())
    print("mensaje :", plaintext.decode("ascii", errors="replace"))
    print("etiqueta GCM correcta")


if __name__ == "__main__":
    main()
