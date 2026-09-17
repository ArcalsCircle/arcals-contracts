// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { ArcalMirror } from "./ArcalMirror.sol";
import { IArcalsErrors } from "./interfaces/IArcalsErrors.sol";
import { IArcalsMetadataRenderer } from "./interfaces/IArcalsMetadataRenderer.sol";

/// @notice Artwork for Arcals. Each registered Arcal is drawn fully on-chain as a ring of its 360
///         Pi digits, one digit per degree clockwise from the top, with an inner tick per degree
///         whose length and brightness follow that digit. Before its content is registered the
///         digits are not on-chain yet, so metadata points to `imageBaseUrl`, which serves the
///         byte-identical artwork; marketplaces that cache the first metadata never keep a bare
///         ring. With an empty `imageBaseUrl` unregistered Arcals show the bare ring on-chain.
/// @dev Stateless and replaceable: governance points the Mirror at a new renderer to change the
///      artwork, and the Mirror falls back to built-in metadata if this contract fails.
contract ArcalsMetadataRenderer is IArcalsMetadataRenderer, IArcalsErrors {
    using Strings for uint256;

    ArcalMirror public immutable mirror;
    /// @notice Prefix of the off-chain image for unregistered Arcals: `<imageBaseUrl><id>/image.svg`.
    string public imageBaseUrl;

    /// @dev Per degree: int16 sin * 1e4, then int16 -cos * 1e4 (screen coordinates, y down).
    bytes private constant TRIG =
        hex"0000d8f000afd8f2015dd8f6020bd8fe02bad9080368d9160415d92704c3d93b0570d951061cd96b06c8d9880774d9a8081fd9cb08cad9f00973da190a1cda450ac4da730b6cdaa50c12dad90cb8db110d5cdb4b0e00db880ea2dbc80f43dc0b0fe3dc511082dc991120dce411bcdd321257dd8312f0ddd61388de2c141ede8414b3dee01546df3d15d8df9e1668e00016f6e0661782e0ce180de1381895e1a5191ce21419a1e2851a23e2f91aa4e36e1b23e3e71b9fe4611c19e4dd1c92e55c1d07e5dd1d7be65f1dece6e41e5be76b1ec8e7f31f32e87e1f9ae90a2000e9982062ea2820c3eaba2120eb4d217cebe221d4ec78222aed10227deda922ceee44231ceee02367ef7e23aff01d23f5f0bd2438f15e2478f20024b5f2a424eff3482527f3ee255bf494258df53c25bbf5e425e7f68d2610f7362635f7e12658f88c2678f9382695f9e426affa9026c5fb3d26d9fbeb26eafc9826f8fd462702fdf5270afea3270eff5127100000270e00af270a015d2702020b26f802ba26ea036826d9041526c504c326af05702695061c267806c8265807742635081f261008ca25e7097325bb0a1c258d0ac4255b0b6c25270c1224ef0cb824b50d5c24780e0024380ea223f50f4323af0fe323671082231c112022ce11bc227d1257222a12f021d41388217c141e212014b320c31546206215d8200016681f9a16f61f3217821ec8180d1e5b18951dec191c1d7b19a11d071a231c921aa41c191b231b9f1b9f1b231c191aa41c921a231d0719a11d7b191c1dec18951e5b180d1ec817821f3216f61f9a1668200015d82062154620c314b32120141e217c138821d412f0222a1257227d11bc22ce1120231c108223670fe323af0f4323f50ea224380e0024780d5c24b50cb824ef0c1225270b6c255b0ac4258d0a1c25bb097325e708ca2610081f26350774265806c82678061c2695057026af04c326c5041526d9036826ea02ba26f8020b2702015d270a00af270e00002710ff51270efea3270afdf52702fd4626f8fc9826eafbeb26d9fb3d26c5fa9026aff9e42695f9382678f88c2658f7e12635f7362610f68d25e7f5e425bbf53c258df494255bf3ee2527f34824eff2a424b5f2002478f15e2438f0bd23f5f01d23afef7e2367eee0231cee4422ceeda9227ded10222aec7821d4ebe2217ceb4d2120eaba20c3ea282062e9982000e90a1f9ae87e1f32e7f31ec8e76b1e5be6e41dece65f1d7be5dd1d07e55c1c92e4dd1c19e4611b9fe3e71b23e36e1aa4e2f91a23e28519a1e214191ce1a51895e138180de0ce1782e06616f6e0001668df9e15d8df3d1546dee014b3de84141ede2c1388ddd612f0dd831257dd3211bcdce41120dc991082dc510fe3dc0b0f43dbc80ea2db880e00db4b0d5cdb110cb8dad90c12daa50b6cda730ac4da450a1cda190973d9f008cad9cb081fd9a80774d98806c8d96b061cd9510570d93b04c3d9270415d9160368d90802bad8fe020bd8f6015dd8f200afd8f00000d8f2ff51d8f6fea3d8fefdf5d908fd46d916fc98d927fbebd93bfb3dd951fa90d96bf9e4d988f938d9a8f88cd9cbf7e1d9f0f736da19f68dda45f5e4da73f53cdaa5f494dad9f3eedb11f348db4bf2a4db88f200dbc8f15edc0bf0bddc51f01ddc99ef7edce4eee0dd32ee44dd83eda9ddd6ed10de2cec78de84ebe2dee0eb4ddf3deabadf9eea28e000e998e066e90ae0cee87ee138e7f3e1a5e76be214e6e4e285e65fe2f9e5dde36ee55ce3e7e4dde461e461e4dde3e7e55ce36ee5dde2f9e65fe285e6e4e214e76be1a5e7f3e138e87ee0cee90ae066e998e000ea28df9eeabadf3deb4ddee0ebe2de84ec78de2ced10ddd6eda9dd83ee44dd32eee0dce4ef7edc99f01ddc51f0bddc0bf15edbc8f200db88f2a4db4bf348db11f3eedad9f494daa5f53cda73f5e4da45f68dda19f736d9f0f7e1d9cbf88cd9a8f938d988f9e4d96bfa90d951fb3dd93bfbebd927fc98d916fd46d908fdf5d8fefea3d8f6ff51d8f2";

    int256 private constant CENTER_X = 5000;
    int256 private constant CENTER_Y = 4700;
    int256 private constant TEXT_RADIUS = 4380;
    int256 private constant TICK_RADIUS = 4180;
    int256 private constant HALF_ADVANCE = 38;
    int256 private constant HALF_CAP = 45;
    uint256 private constant BUFFER_BYTES = 20_000;

    string private constant DESCRIPTION =
        "Arcals: 1,000,000 Pi inscriptions on Arc. Arcal #n holds the 360 consecutive decimal digits of Pi at positions (n-1)*360+1 to n*360, drawn one digit per degree. One Arcal and 360 ARCL are two forms of the same share. No rarity is defined by the protocol.";

    string private constant SVG_HEAD =
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 1000'><defs><linearGradient id='s' x1='38' y1='8' x2='962' y2='932' gradientUnits='userSpaceOnUse'><stop stop-color='#5b6875'/><stop offset='.3' stop-color='#fff'/><stop offset='.6' stop-color='#3a4550'/><stop offset='.8' stop-color='#eef5fb'/><stop offset='1' stop-color='#8a98a6'/></linearGradient><filter id='g' x='-50%' y='-50%' width='200%' height='200%'><feGaussianBlur stdDeviation='10'/></filter></defs><rect width='1000' height='1000' fill='#030405'/><circle cx='500' cy='470' r='462' fill='none' stroke='#b9cbdc' stroke-opacity='.16' stroke-width='12' filter='url(#g)'/><circle cx='500' cy='470' r='462' fill='none' stroke='url(#s)' stroke-width='2'/>";

    constructor(address mirror_, string memory imageBaseUrl_) {
        if (mirror_ == address(0)) revert ZeroAddress();
        mirror = ArcalMirror(mirror_);
        imageBaseUrl = imageBaseUrl_;
    }

    function tokenURI(uint256 id) external view override returns (string memory) {
        (uint256 startDigit, uint256 endDigit) = mirror.piRange(id);
        bool registered = mirror.contentRegistered(id);
        string memory json = string.concat(
            string.concat(
                '{"name":"Arcal #',
                id.toString(),
                '","description":"',
                DESCRIPTION,
                '","external_url":"https://arcals.fun","image":"',
                imageURI(id),
                '"'
            ),
            string.concat(
                ',"pi_digit_start":',
                startDigit.toString(),
                ',"pi_digit_end":',
                endDigit.toString(),
                ',"content_registered":',
                registered ? "true" : "false",
                ',"content_hash":"',
                registered ? uint256(mirror.contentHash(id)).toHexString(32) : "",
                '","in_vault":',
                _inVault(id) ? "true" : "false"
            ),
            ',"attributes":[{"trait_type":"Pi digit start","display_type":"number","value":',
            startDigit.toString(),
            '},{"trait_type":"Pi digit end","display_type":"number","value":',
            endDigit.toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function contractURI() external pure override returns (string memory) {
        string memory image = string.concat(
            SVG_HEAD,
            "<text x='500' y='500' text-anchor='middle' font-family='sans-serif' font-size='120' font-weight='300' letter-spacing='-4' fill='#eef3f9'>arcals</text></svg>"
        );
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"Arcals","description":"',
                        DESCRIPTION,
                        '","external_link":"https://arcals.fun","image":"data:image/svg+xml;base64,',
                        Base64.encode(bytes(image)),
                        '"}'
                    )
                )
            )
        );
    }

    /// @notice The image field of the token metadata: an on-chain SVG data URI once content is
    ///         registered (or when no base URL is set), otherwise the off-chain image URL.
    function imageURI(uint256 id) public view returns (string memory) {
        if (!mirror.contentRegistered(id) && bytes(imageBaseUrl).length != 0) {
            mirror.piRange(id);
            return string.concat(imageBaseUrl, id.toString(), "/image.svg");
        }
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(imageSVG(id))));
    }

    /// @notice The raw SVG artwork for an Arcal ID.
    function imageSVG(uint256 id) public view returns (string memory) {
        (uint256 startDigit, uint256 endDigit) = mirror.piRange(id);
        bytes memory out = new bytes(BUFFER_BYTES);
        uint256 length = _write(out, 0, bytes(SVG_HEAD));
        bytes memory packed = mirror.contentDigits(id);
        if (packed.length == 180) length = _writeDigits(out, length, packed);
        length = _write(
            out,
            length,
            "<text x='500' y='968' text-anchor='middle' font-family='monospace' font-size='24' letter-spacing='3' fill='#8f9cad'>"
        );
        length = _write(out, length, unicode"π ");
        length = _writeGrouped(out, length, startDigit);
        length = _write(out, length, unicode" – ");
        length = _writeGrouped(out, length, endDigit);
        length = _write(out, length, "</text></svg>");
        assembly ("memory-safe") {
            mstore(out, length)
        }
        return string(out);
    }

    function _inVault(uint256 id) private view returns (bool) {
        return mirror.ownerOf(id) == mirror.vault();
    }

    function _writeDigits(bytes memory out, uint256 length, bytes memory packed)
        private
        pure
        returns (uint256)
    {
        bytes memory trig = TRIG;
        bytes memory digits = new bytes(360);
        for (uint256 index = 0; index < 180; ++index) {
            uint8 pair = uint8(packed[index]);
            digits[index * 2] = bytes1(0x30 + (pair >> 4));
            digits[index * 2 + 1] = bytes1(0x30 + (pair & 0x0f));
        }

        length = _write(
            out,
            length,
            "<g transform='scale(.1)'><text font-family='monospace' font-size='125' font-weight='700' fill='#fff' x='"
        );
        // Glyph origin = centre on the text circle minus the rotated half advance and half cap
        // height, so each rotated digit is centred on its degree.
        for (uint256 degree = 0; degree < 360; ++degree) {
            (int256 sine, int256 negCosine) = _unit(trig, degree);
            int256 x = CENTER_X + (TEXT_RADIUS * sine) / 10_000;
            x -= (HALF_ADVANCE * -negCosine + HALF_CAP * sine) / 10_000;
            if (degree != 0) length = _writeByte(out, length, " ");
            length = _writeUint(out, length, _toUint(x));
        }
        length = _write(out, length, "' y='");
        for (uint256 degree = 0; degree < 360; ++degree) {
            (int256 sine, int256 negCosine) = _unit(trig, degree);
            int256 y = CENTER_Y + (TEXT_RADIUS * negCosine) / 10_000;
            y -= (HALF_ADVANCE * sine - HALF_CAP * -negCosine) / 10_000;
            if (degree != 0) length = _writeByte(out, length, " ");
            length = _writeUint(out, length, _toUint(y));
        }
        length = _write(out, length, "' rotate='");
        for (uint256 degree = 0; degree < 360; ++degree) {
            if (degree != 0) length = _writeByte(out, length, " ");
            length = _writeUint(out, length, degree);
        }
        length = _write(out, length, "'>");
        length = _write(out, length, digits);
        length = _write(
            out,
            length,
            "</text><g stroke='#e4edf6' stroke-width='22' stroke-linecap='round' fill='none'>"
        );
        int256 inner = TICK_RADIUS - 50;
        for (uint256 value = 0; value < 10; ++value) {
            bool opened;
            for (uint256 degree = 0; degree < 360; ++degree) {
                if (uint8(digits[degree]) - 0x30 != value) continue;
                if (!opened) {
                    length = _write(out, length, "<path stroke-opacity='.");
                    length = _writeUint(out, length, 30 + 7 * value);
                    length = _write(out, length, "' d='");
                    opened = true;
                }
                (int256 sine, int256 negCosine) = _unit(trig, degree);
                length = _writeByte(out, length, "M");
                length = _writePoint(out, length, TICK_RADIUS, sine, negCosine);
                length = _writeByte(out, length, "L");
                length = _writePoint(out, length, inner, sine, negCosine);
            }
            if (opened) length = _write(out, length, "'/>");
            inner -= 95;
        }
        return _write(out, length, "</g></g>");
    }

    function _writePoint(
        bytes memory out,
        uint256 length,
        int256 radius,
        int256 sine,
        int256 negCosine
    ) private pure returns (uint256) {
        length = _writeUint(out, length, _toUint(CENTER_X + (radius * sine) / 10_000));
        length = _writeByte(out, length, " ");
        return _writeUint(out, length, _toUint(CENTER_Y + (radius * negCosine) / 10_000));
    }

    function _unit(bytes memory trig, uint256 degree)
        private
        pure
        returns (int256 sine, int256 negCosine)
    {
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(add(trig, 0x20), mul(degree, 4)))
        }
        // The table is 360 * 4 bytes, so the top 32 bits of each read are always in range.
        // forge-lint: disable-next-line(unsafe-typecast)
        sine = int256(int16(uint16(word >> 240)));
        // forge-lint: disable-next-line(unsafe-typecast)
        negCosine = int256(int16(uint16(word >> 224)));
    }

    function _toUint(int256 value) private pure returns (uint256) {
        // Every coordinate lies inside the 10,000-unit canvas.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(value);
    }

    function _write(bytes memory out, uint256 length, bytes memory data)
        private
        pure
        returns (uint256)
    {
        assembly ("memory-safe") {
            mcopy(add(add(out, 0x20), length), add(data, 0x20), mload(data))
        }
        return length + data.length;
    }

    function _writeByte(bytes memory out, uint256 length, bytes1 value)
        private
        pure
        returns (uint256)
    {
        out[length] = value;
        return length + 1;
    }

    function _writeUint(bytes memory out, uint256 length, uint256 value)
        private
        pure
        returns (uint256)
    {
        return _write(out, length, bytes(value.toString()));
    }

    /// @dev Decimal with thousands separators, e.g. 356,400,001.
    function _writeGrouped(bytes memory out, uint256 length, uint256 value)
        private
        pure
        returns (uint256)
    {
        bytes memory plain = bytes(value.toString());
        for (uint256 index = 0; index < plain.length; ++index) {
            if (index != 0 && (plain.length - index) % 3 == 0) {
                length = _writeByte(out, length, ",");
            }
            length = _writeByte(out, length, plain[index]);
        }
        return length;
    }
}
