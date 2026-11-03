// Known-answer checks over the same catboost libraries the fuzz harnesses exercise.
#include <library/cpp/cgiparam/cgiparam.h>
#include <library/cpp/containers/flat_hash/flat_hash.h>
#include <library/cpp/http/io/stream.h>
#include <library/cpp/json/json_reader.h>
#include <library/cpp/json/json_writer.h>
#include <library/cpp/string_utils/base64/base64.h>

#include <util/stream/mem.h>
#include <util/stream/output.h>

static int Failures = 0;

#define CHECK(name, cond)                                  \
    do {                                                   \
        if (cond) {                                        \
            Cout << "PASS " << name << Endl;               \
        } else {                                           \
            Cout << "FAIL " << name << Endl;               \
            ++Failures;                                    \
        }                                                  \
    } while (0)

int main() {
    CHECK("base64_encode", Base64Encode("foobar") == "Zm9vYmFy");
    CHECK("base64_encode_padded", Base64Encode("fo") == "Zm8=");
    CHECK("base64_decode", Base64Decode("Zm9vYg==") == "foob");
    CHECK("base64_url", Base64EncodeUrl("\xfb\xff") == "-_8,");

    {
        TCgiParameters p("a=b&c=d%20e&a=f");
        CHECK("cgi_get", p.Get("c") == "d e");
        CHECK("cgi_count", p.NumOfValues("a") == 2);
        CHECK("cgi_second_value", p.Get("a", 1) == "f");
        CHECK("cgi_print", p.Print() == "a=b&a=f&c=d+e");
    }

    {
        NJson::TJsonValue v;
        bool ok = NJson::ReadJsonTree(TStringBuf(R"({"b":[1,2,{"c":"x"}],"a":true})"), &v);
        CHECK("json_parse", ok && v["b"][2]["c"].GetString() == "x" && v["b"][1].GetInteger() == 2);
        CHECK("json_write", NJson::WriteJson(v, false, true) == R"({"a":true,"b":[1,2,{"c":"x"}]})");
        NJson::TJsonValue bad;
        CHECK("json_reject", !NJson::ReadJsonTree(TStringBuf("{\"a\":"), &bad));
    }

    {
        const TStringBuf raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-K: v\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n";
        TMemoryInput mi(raw.data(), raw.size());
        THttpInput in(&mi);
        TString body = in.ReadAll();
        CHECK("http_chunked_body", body == "abcde");
        CHECK("http_header", in.Headers().Count() == 2);
    }

    {
        NFH::TFlatHashMap<int, int> m;
        for (int i = 0; i < 100; ++i) {
            m[i] = i * i;
        }
        CHECK("flat_hash_lookup", m.size() == 100 && m.at(12) == 144 && m.find(100) == m.end());
    }

    return Failures ? 1 : 0;
}
