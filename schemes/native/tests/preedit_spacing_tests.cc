// Public, standalone tests for the exact production display helper.
// No dictionary, session, user input, Windows UI or IME process is loaded.
#include <rime/preedit_spacing.h>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

struct Display {
  std::string text;
  size_t caret_pos;
  size_t sel_start;
  size_t sel_end;
};

struct Result {
  std::string id;
  bool passed;
};
std::vector<Result> results;

void Check(const char* id,
           Display value,
           const std::string& raw,
           size_t start,
           size_t end,
           size_t caret,
           const std::string& marker,
           const std::string& plan,
           bool applies,
           Display expected) {
  bool changed = rime::preedit_spacing::Apply(
      &value, raw, start, end, caret, marker, plan);
  bool passed = changed == applies && value.text == expected.text &&
                value.caret_pos == expected.caret_pos &&
                value.sel_start == expected.sel_start &&
                value.sel_end == expected.sel_end;
  results.push_back({id, passed});
  if (!passed)
    std::cerr << "FAILED: " << id << " [" << value.text << "] "
              << value.caret_pos << ',' << value.sel_start << ','
              << value.sel_end << '\n';
}

int main(int argc, char** argv) {
  const std::string cursor = "\xe2\x80\xb8";
  const Display partial{"qi jinahao", 10, 0, 6};
  Check("whole-candidate-unchanged", {"qi jina hao", 11, 0, 11},
        "qijinahao", 0, 9, 9, "", "0:9:9:9|", false,
        {"qi jina hao", 11, 0, 11});
  Check("partial-qijinahao", partial, "qijinahao", 0, 5, 9, "",
        "0:5:9:9|5,6", true, {"qi jin a hao", 12, 0, 6});
  Check("partial-qijinanhao", {"qi jinanhao", 11, 0, 6},
        "qijinanhao", 0, 5, 10, "", "0:5:10:10|5,7", true,
        {"qi jin an hao", 13, 0, 6});
  Check("jin-keeps-a", {"jina", 4, 0, 3}, "jina", 0, 3, 4, "",
        "0:3:4:4|3", true, {"jin a", 5, 0, 3});
  Check("soft-cursor-at-end", {partial.text + cursor, 10, 0, 6},
        "qijinahao", 0, 5, 9, cursor, "0:5:9:9|5,6", true,
        {"qi jin a hao" + cursor, 12, 0, 6});
  Check("soft-cursor-at-tail-start", {"qi jin" + cursor + "ahao", 6, 0, 6},
        "qijinahao", 0, 5, 5, cursor, "0:5:9:5|5,6", true,
        {"qi jin " + cursor + "a hao", 7, 0, 6});
  Check("soft-cursor-inside-tail", {"qi jinah" + cursor + "ao", 8, 0, 6},
        "qijinahao", 0, 5, 7, cursor, "0:5:9:7|5,6", true,
        {"qi jin a h" + cursor + "ao", 10, 0, 6});
  Check("native-prompt-preserved", {partial.text + cursor + "?", 10, 0, 6},
        "qijinahao", 0, 5, 9, cursor + "?", "0:5:9:9|5,6", true,
        {"qi jin a hao" + cursor + "?", 12, 0, 6});
  const std::string selected = "\xe6\x88\x91\xe5\x80\x91";
  Check("selected-prefix-byte-length-differs", {selected + partial.text, 16, 6, 12},
        "womenqijinahao", 5, 10, 14, "", "5:10:14:14|10,11", true,
        {selected + "qi jin a hao", 18, 6, 12});
  Check("existing-space-not-doubled", {"qi jin ahao", 11, 0, 7},
        "qijinahao", 0, 5, 9, "", "0:5:9:9|5,6", true,
        {"qi jin a hao", 12, 0, 7});
  Check("manual-apostrophe-preserved", {"qi jin'ahao", 11, 0, 7},
        "qijin'ahao", 0, 6, 10, "", "0:6:10:10|6,7", true,
        {"qi jin'a hao", 12, 0, 7});
  Check("switch-to-other-highlighted-end", {"qi jinahao", 10, 0, 7},
        "qijinahao", 0, 6, 9, "", "0:6:9:9|6", true,
        {"qi jina hao", 11, 0, 7});

  const char* invalid[] = {
      "", "0:5:9|5", "0:5:9:9/5", "0:5:9:9|5,", "0:5:9:9|5,5",
      "0:5:9:9|6,5", "0:5:9:9|4", "0:5:9:9|9", "0:5:9:9|-1",
      "0:5:9:9|five", "0:5:9:9|5\n6", "0:5:9:9|5;6",
      "0:5:99999999999999999999999999999999:9|5",
      "1:5:9:9|5", "0:6:9:9|6", "0:5:8:9|5", "0:5:9:8|5"};
  for (size_t i = 0; i < sizeof(invalid) / sizeof(*invalid); ++i) {
    std::string id = "invalid-or-stale-plan-" + std::to_string(i);
    Check(id.c_str(), partial, "qijinahao", 0, 5, 9, "", invalid[i],
          false, partial);
  }
  Check("native-suffix-mismatch-unchanged", partial, "qijinxhao", 0, 5, 9, "",
        "0:5:9:9|5,6", false, partial);
  Check("native-selection-mismatch-unchanged", {partial.text, 10, 0, 5},
        "qijinahao", 0, 5, 9, "", "0:5:9:9|5,6", false,
        {partial.text, 10, 0, 5});
  Check("missing-cursor-unchanged", partial, "qijinahao", 0, 5, 9, cursor,
        "0:5:9:9|5,6", false, partial);
  Check("no-break-no-change", partial, "qijinahao", 0, 5, 9, "",
        "0:5:9:9|", false, partial);
  const std::string non_ascii = "qijin\xe5\xa5\xbd";
  Check("no-utf8-byte-split", {"qi jin\xe5\xa5\xbd", 9, 0, 6},
        non_ascii, 0, 5, 8, "", "0:5:8:8|5", false,
        {"qi jin\xe5\xa5\xbd", 9, 0, 6});

  bool passed = true;
  for (const auto& result : results)
    passed = passed && result.passed;
  std::ostream* output = &std::cout;
  std::ofstream file;
  if (argc == 2) {
    file.open(argv[1], std::ios::binary);
    if (!file)
      return 2;
    output = &file;
  }
  *output << "{\"Passed\":" << (passed ? "true" : "false")
          << ",\"Checks\":" << results.size()
          << ",\"ProductionHelper\":true,\"EngineLoaded\":false,\"Rows\":[";
  for (size_t i = 0; i < results.size(); ++i) {
    if (i)
      *output << ',';
    *output << "{\"Id\":\"" << results[i].id << "\",\"Passed\":"
            << (results[i].passed ? "true" : "false") << '}';
  }
  *output << "]}\n";
  return passed ? 0 : 1;
}
