<?php
// Runtime for publr-portable/scalars/1. Kept inside generated artifacts so a
// deployment needs PHP only. Requiring multiple component files is safe.
namespace Publr\Portable {
if (!class_exists(V1::class, false)) {
    enum UndefinedValue { case Value; }
    final class Html {
        public function __construct(public readonly string $value) {}
    }
    final class V1 {
        public const SEMANTICS_VERSION = 1;
        public static function undefined(): UndefinedValue { return UndefinedValue::Value; }
        public static function nullish(mixed $v): bool { return $v === null || $v === self::undefined(); }
        public static function truthy(mixed $v): bool {
            if (self::nullish($v) || $v === false) return false;
            if (is_float($v) || is_int($v)) return $v != 0 && !is_nan((float)$v);
            if (is_string($v)) return $v !== '';
            return true;
        }
        public static function logicalAnd(mixed $v, callable $right): mixed { return self::truthy($v) ? $right() : $v; }
        public static function logicalOr(mixed $v, callable $right): mixed { return self::truthy($v) ? $v : $right(); }
        public static function coalesce(mixed $v, callable $right): mixed { return self::nullish($v) ? $right() : $v; }
        public static function bits(float $v): string { return bin2hex(pack('E', $v)); }
        public static function fromBits(string $hex): float {
            if (!preg_match('/\A[0-9a-fA-F]{16}\z/D', $hex)) throw new \InvalidArgumentException('Invalid binary64 envelope');
            return unpack('Evalue', hex2bin($hex))['value'];
        }
        public static function encode(mixed $v): array {
            if ($v === self::undefined()) return ['undefined'];
            if ($v === null) return ['null'];
            if (is_bool($v)) return ['boolean', $v];
            if (is_int($v) || is_float($v)) return ['number', self::bits((float)$v)];
            if (is_string($v) && preg_match('//u', $v) === 1) return ['string', $v];
            throw new \InvalidArgumentException('Unsupported portable scalar');
        }
        public static function decode(mixed $v): mixed {
            if (!is_array($v) || !array_is_list($v)) throw new \InvalidArgumentException('Invalid scalar envelope');
            if ($v === ['undefined']) return self::undefined();
            if ($v === ['null']) return null;
            if (count($v) === 2) {
                if ($v[0] === 'boolean' && is_bool($v[1])) return $v[1];
                if ($v[0] === 'number' && is_string($v[1])) return self::fromBits($v[1]);
                if ($v[0] === 'string' && is_string($v[1]) && preg_match('//u', $v[1]) === 1) return $v[1];
            }
            throw new \InvalidArgumentException('Invalid scalar envelope');
        }
        public static function prop(array $props, string $name, string $kind, bool $optional, mixed $default): mixed {
            $value = array_key_exists($name, $props) ? $props[$name] : self::undefined();
            if ($value === self::undefined()) $value = $default;
            if ($optional && $value === self::undefined()) return $value;
            if ($kind === 'number' && (is_int($value) || is_float($value))) return (float)$value;
            if ($kind === 'boolean' && is_bool($value)) return $value;
            if ($kind === 'string' && is_string($value) && preg_match('//u', $value) === 1) return $value;
            throw new \InvalidArgumentException('Invalid portable prop: ' . $name);
        }
        public static function minimum(float $a, float $b): float {
            if (is_nan($a) || is_nan($b)) return NAN;
            if ($a == 0 && $b == 0) return (fdiv(1.0, $a) < 0 || fdiv(1.0, $b) < 0) ? -0.0 : 0.0;
            return $a < $b ? $a : $b;
        }
        public static function maximum(float $a, float $b): float {
            if (is_nan($a) || is_nan($b)) return NAN;
            if ($a == 0 && $b == 0) return (fdiv(1.0, $a) > 0 || fdiv(1.0, $b) > 0) ? 0.0 : -0.0;
            return $a > $b ? $a : $b;
        }
        public static function remainder(float $a, float $b): float {
            if (is_nan($a) || is_nan($b) || is_infinite($a) || $b == 0) return NAN;
            if (is_infinite($b) || $a == 0) return $a;
            return fmod($a, $b);
        }
        public static function number(float $v): string {
            if (is_nan($v)) return 'NaN';
            if (is_infinite($v)) return $v < 0 ? '-Infinity' : 'Infinity';
            if ($v == 0) return '0';
            // PHP's dtoa mode 0 provides shortest round-tripping digits. Apply
            // ECMAScript's notation thresholds instead of PHP's JSON notation.
            $precision = ini_get('serialize_precision');
            if ($precision !== '-1' && ini_set('serialize_precision', '-1') === false)
                throw new \RuntimeException('Portable rendering requires serialize_precision=-1');
            try { $raw = json_encode(abs($v), JSON_THROW_ON_ERROR); }
            finally { if ($precision !== '-1') ini_set('serialize_precision', $precision); }
            $parts = explode('e', strtolower($raw));
            $mantissa = $parts[0];
            $point = strpos($mantissa, '.');
            $decimal = ($point === false ? strlen($mantissa) : $point) + (isset($parts[1]) ? (int)$parts[1] : 0);
            $digits = str_replace('.', '', $mantissa);
            while (strlen($digits) > 1 && $digits[0] === '0') { $digits = substr($digits, 1); $decimal--; }
            $digits = rtrim($digits, '0');
            $length = strlen($digits);
            if ($decimal > 0 && $decimal <= 21) {
                $text = $decimal >= $length ? $digits . str_repeat('0', $decimal - $length) : substr($digits, 0, $decimal) . '.' . substr($digits, $decimal);
            } elseif ($decimal <= 0 && $decimal > -6) {
                $text = '0.' . str_repeat('0', -$decimal) . $digits;
            } else {
                $exponent = $decimal - 1;
                $text = $digits[0] . ($length > 1 ? '.' . substr($digits, 1) : '') . 'e' . ($exponent >= 0 ? '+' : '') . $exponent;
            }
            return ($v < 0 ? '-' : '') . $text;
        }
        public static function text(mixed $v): string {
            if (is_float($v) || is_int($v)) return self::number((float)$v);
            if (is_string($v)) return $v;
            if (is_bool($v)) return $v ? 'true' : 'false';
            if ($v === null) return 'null';
            if ($v === self::undefined()) return 'undefined';
            throw new \InvalidArgumentException('Unsupported text value');
        }
        public static function escape(string $v): string { return htmlspecialchars($v, ENT_QUOTES | ENT_SUBSTITUTE | ENT_HTML5, 'UTF-8', true); }
        public static function child(mixed $v): string {
            if ($v instanceof Html) return $v->value;
            if (self::nullish($v) || is_bool($v)) return '';
            return self::escape(self::text($v));
        }
        public static function fragment(array $children): Html { return new Html(implode('', array_map(self::child(...), $children))); }
        public static function element(string $tag, array $attributes, array $children): Html {
            $html = '<' . $tag;
            $booleans = ['allowfullscreen', 'async', 'autofocus', 'autoplay', 'checked', 'controls', 'default', 'defer', 'disabled', 'formnovalidate', 'hidden', 'inert', 'ismap', 'itemscope', 'loop', 'multiple', 'muted', 'nomodule', 'novalidate', 'open', 'playsinline', 'readonly', 'required', 'reversed', 'selected'];
            foreach ($attributes as [$name, $v]) {
                if (self::nullish($v)) continue;
                if (in_array(strtolower($name), $booleans, true)) {
                    if (self::truthy($v)) $html .= ' ' . $name . '=""';
                } elseif (str_starts_with($name, 'aria-') && is_bool($v)) {
                    $html .= ' ' . $name . '="' . self::text($v) . '"';
                } elseif ($v !== false) {
                    $html .= ' ' . $name . '="' . self::escape($v === true ? '' : self::text($v)) . '"';
                }
            }
            $html .= '>';
            if (!in_array(strtolower($tag), ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'], true))
                $html .= self::fragment($children)->value . '</' . $tag . '>';
            return new Html($html);
        }
    }
}
}
