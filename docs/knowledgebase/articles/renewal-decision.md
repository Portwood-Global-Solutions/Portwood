An account owner wants to know what to do before a renewal meeting. This one-page PDF starts with a recommendation, backs it with the account’s contract and usage figures, and shows which team needs attention.

[Open the decision brief](https://portwood.dev/demos/studio/renewal-brief.pdf) · [Read the text edition](https://portwood.dev/demos/studio/renewal-brief-reading.html) · [Download the design files](https://portwood.dev/demos/studio/document-studio.zip)

[View HTML](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/document-studio/renewal-brief.html) · [View data](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/document-studio/renewal-brief.json)

![Renewal decision brief showing the account recommendation, contract value, service cases and team adoption bars](docs/images/userguide/v3.64/renewal-decision.png)

#### Make the decision before you write the headline

The sample’s teams have **72 active seats out of 100 licensed**. The account target is **80%**, so the recommendation is **Book an adoption review**. Calculate the overall rate from the total seats. An unweighted average of the team percentages gives a different answer.

Have the Flow or provider supply `HasUsage`, `AtTarget`, `Adoption` and `Threshold` together. Set `HasUsage` to false for a missing reporting period or a zero denominator. Set `AtTarget` from the data source’s comparison of the measured rate and the account’s agreed threshold. Keep that logic where the business rule lives.

| Input state | What the reader sees |
| --- | --- |
| Usage is available and below target | **Book an adoption review**, with the agreed threshold and the team breakdown. |
| Usage meets or exceeds target | **Prepare renewal terms**, with the same underlying measurements. |
| No usable measurement | **Request usage data** and an **Unknown** metric. The team chart is omitted. |

#### Print a bar the reader can check

The bar is ordinary HTML. The data supplies a numeric percentage between 0 and 100. Give the track a fixed height and print the value alongside it so the document still makes sense in grayscale.

```html
<tr>
    <td>{#Teams}{Name}</td><td>{Active} / {Licensed}</td>
    <td>{Percent}%<div class="scale"><div class="fill" style="width:{Percent}%;"></div></div>{/Teams}</td>
</tr>
```

The sample uses the same printed width for every track. Test 0, 50 and 100 before adding more teams. If your metric can exceed 100%, decide how you want to label it and bound the display width in the data.

#### Adapt the story

Try the supplied **72%**, then change the data to **84%**, `AtTarget` to true and the team counts to match. Finally set `HasUsage` to false. Generate all three files. The headline, metric band and chart should agree. The same pattern works for a project health report, a grant milestone or an account statement. [Run the example](#document-studio)
