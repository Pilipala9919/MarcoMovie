package com.pilipala.marcomovie;

import java.util.List;
import java.util.Map;

/** Shared touch/remote filter chooser using the source's own values. */
final class VideoFilterDialog {
    static void show(
            MainActivity a,
            List<VideoFilters.Definition> definitions,
            Map<String, String> selections,
            Runnable changed) {
        String[] labels = new String[definitions.size() + 1];
        for (int i = 0; i < definitions.size(); i++) {
            VideoFilters.Definition def = definitions.get(i);
            labels[i] = def.label + "：" + def.labelFor(selections.get(def.dimension));
        }
        labels[definitions.size()] = "清除全部筛选";
        if (!a.isTvDevice()) {
            MobileShell.showDrawerPicker(
                    a,
                    "影视筛选",
                    "选择筛选维度，或一键重置当前筛选条件",
                    labels,
                    -1,
                    index -> {
                        if (index < 0 || index > definitions.size()) return;
                        if (index == definitions.size()) {
                            selections.clear();
                            changed.run();
                            return;
                        }
                        VideoFilters.Definition def = definitions.get(index);
                        String[] options = new String[def.choices.size()];
                        int checked = 0;
                        for (int n = 0; n < options.length; n++) {
                            options[n] = def.choices.get(n).label;
                            if (def.choices.get(n).value.equals(selections.get(def.dimension)))
                                checked = n;
                        }
                        MobileShell.showDrawerPicker(
                                a,
                                def.label,
                                def.remote ? "" : "按已加载影片资料筛选",
                                options,
                                checked,
                                n -> {
                                    if (n < 0 || n >= def.choices.size()) return;
                                    String value = def.choices.get(n).value;
                                    if (value.isEmpty()) selections.remove(def.dimension);
                                    else selections.put(def.dimension, value);
                                    changed.run();
                                });
                    });
            return;
        }
        new AppDialog.Builder(a)
                .setTitle("影视筛选")
                .wrapChoices()
                .setItems(
                        labels,
                        (dialog, index) -> {
                            if (index == definitions.size()) {
                                selections.clear();
                                changed.run();
                                return;
                            }
                            VideoFilters.Definition def = definitions.get(index);
                            String[] options = new String[def.choices.size()];
                            int checked = 0;
                            for (int n = 0; n < options.length; n++) {
                                options[n] = def.choices.get(n).label;
                                if (def.choices.get(n).value.equals(selections.get(def.dimension)))
                                    checked = n;
                            }
                            new AppDialog.Builder(a)
                                    .setTitle(def.label + (def.remote ? "" : " · 按已加载影片资料筛选"))
                                    .wrapChoices()
                                    .setSingleChoiceItems(
                                            options,
                                            checked,
                                            (choice, n) -> {
                                                String value = def.choices.get(n).value;
                                                if (value.isEmpty())
                                                    selections.remove(def.dimension);
                                                else selections.put(def.dimension, value);
                                                changed.run();
                                            })
                                    .setNegativeButton("取消", null)
                                    .show();
                        })
                .setNegativeButton("关闭", null)
                .show();
    }
}
