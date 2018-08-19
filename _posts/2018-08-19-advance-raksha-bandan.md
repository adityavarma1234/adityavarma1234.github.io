---
layout: rakhi
title: 'Advance Raksha Bandan'
date: 2018-08-19
---

* Happy rakhsa bandan sowmya
* Thanks for being the best sister a brother could ask for.
{% highlight ruby %}
class Family
  attr_accessor :father, :mother, :son, :daughter
  
  def initialize(father:, mother:, son:, daughter:)
    @father = father
    @mother = mother
    @son = son
    @daughter = daughter
  end

  def rakhshabandan
    daughter.tie_rakhi
    son.gives_gift
    son.thank_sis
    son.thank_parents
    daughter.thank_parents
    'Lived happily ever after'
  end
end
{% endhighlight %}
